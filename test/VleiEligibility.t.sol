// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IEAS, Attestation} from "@eas/IEAS.sol";
import {IEligibility} from "../src/IEligibility.sol";
import {VleiEligibility} from "../src/VleiEligibility.sol";

/// @dev Minimal stand-in for EAS: the real contract pins solc 0.8.28 and cannot be
///      compiled into this 0.8.24 project. Only `getAttestation` is exercised.
contract MockEAS {
    mapping(bytes32 => Attestation) private _att;

    function set(Attestation memory a) external {
        _att[a.uid] = a;
    }

    function revoke(bytes32 uid, uint64 at) external {
        _att[uid].revocationTime = at;
    }

    function getAttestation(bytes32 uid) external view returns (Attestation memory) {
        return _att[uid];
    }
}

contract VleiEligibilityTest is Test {
    MockEAS eas;
    VleiEligibility slot;

    bytes32 constant SCHEMA = 0x0b5f333cdb7e06e0d9f7c5fbd7a151bb0d8afbcde17017390ef73b673f841aa7;
    uint256 constant TOPIC = 15; // Shibui VLEI_LEGAL_ENTITY
    address bridge = makeAddr("bridge");
    address holder = makeAddr("holder");
    address other = makeAddr("other");
    uint64 constant RENEWAL = 1_800_000_000 + 300 days;

    function setUp() public {
        vm.warp(1_800_000_000);
        eas = new MockEAS();
        string[] memory types = new string[](2);
        types[0] = "LE";
        types[1] = "ECR";
        slot = new VleiEligibility(IEAS(address(eas)), SCHEMA, bridge, TOPIC, types);
    }

    function _data(string memory credType) internal pure returns (bytes memory) {
        return abi.encode(
            "875500ELOZEL05BVXV37",
            "Global Legal Entity Identifier Foundation Singapore Branch",
            credType,
            "EKYGGh-FtAphGmSZbsuBs_t4qpsjYJ2ZqvMKluq9OxmY",
            keccak256("said"),
            uint64(1_700_000_000) // verifiedAt: years ago, must not matter
        );
    }

    function _attestation(bytes32 uid, address recipient, string memory credType)
        internal
        view
        returns (Attestation memory a)
    {
        a.uid = uid;
        a.schema = SCHEMA;
        a.time = uint64(vm.getBlockTimestamp());
        a.expirationTime = RENEWAL;
        a.revocationTime = 0;
        a.recipient = recipient;
        a.attester = bridge;
        a.revocable = true;
        a.data = _data(credType);
    }

    function _expectNotLive(bytes32 uid, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(VleiEligibility.NotLiveBridgeAttestation.selector, uid, reason));
    }

    function _issue(bytes32 uid, address recipient, string memory credType) internal {
        eas.set(_attestation(uid, recipient, credType));
    }

    /// @dev The single TopicStatus `explain` reports for `wallet`, checked to be on the slot's topic.
    function _status(address wallet) internal view returns (IEligibility.Status) {
        IEligibility.TopicStatus[] memory out = slot.explain(wallet);
        assertEq(out.length, 1);
        assertEq(out[0].topic, TOPIC);
        return out[0].status;
    }

    function _assertStatus(address wallet, IEligibility.Status expected) internal view {
        assertEq(uint256(_status(wallet)), uint256(expected));
    }

    // ---- registration ----

    function test_RegisterLiveAttestation_MakesHolderEligible() public {
        _issue(bytes32(uint256(1)), holder, "ECR");
        slot.register(bytes32(uint256(1)));
        assertTrue(slot.isEligible(holder));
        assertEq(slot.attestationOf(holder), bytes32(uint256(1)));
        _assertStatus(holder, IEligibility.Status.OK);
        assertEq(
            slot.reason(holder),
            "ok: ECR credential of Global Legal Entity Identifier Foundation Singapore Branch (LEI 875500ELOZEL05BVXV37)"
        );
    }

    function test_AnyoneMayRegister_RecipientComesFromTheAttestation() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        vm.prank(other);
        slot.register(bytes32(uint256(1)));
        assertTrue(slot.isEligible(holder));
        assertFalse(slot.isEligible(other));
    }

    function test_RegisterRejects_UnknownUid() public {
        _expectNotLive(bytes32(uint256(99)), "attestation not found on EAS");
        slot.register(bytes32(uint256(99)));
    }

    function test_RegisterRejects_WrongAttester() public {
        Attestation memory a = _attestation(bytes32(uint256(1)), holder, "LE");
        a.attester = other;
        eas.set(a);
        _expectNotLive(bytes32(uint256(1)), "attestation was not issued by the vLEI bridge");
        slot.register(bytes32(uint256(1)));
    }

    function test_RegisterRejects_WrongSchema() public {
        Attestation memory a = _attestation(bytes32(uint256(1)), holder, "LE");
        a.schema = bytes32(uint256(0xdead));
        eas.set(a);
        _expectNotLive(bytes32(uint256(1)), "attestation is not under the vLEI bridge schema");
        slot.register(bytes32(uint256(1)));
    }

    function test_RegisterRejects_RevokedAttestation_SoStrangersCannotDowngradeAWallet() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        _issue(bytes32(uint256(2)), holder, "LE");
        eas.revoke(bytes32(uint256(2)), uint64(vm.getBlockTimestamp()));
        vm.prank(other);
        _expectNotLive(bytes32(uint256(2)), "vLEI attestation revoked");
        slot.register(bytes32(uint256(2)));
        assertEq(slot.attestationOf(holder), bytes32(uint256(1)));
        assertTrue(slot.isEligible(holder));
    }

    function test_Renewal_NewUidReplacesOld() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        Attestation memory renewed = _attestation(bytes32(uint256(2)), holder, "LE");
        renewed.expirationTime = RENEWAL + 365 days;
        eas.set(renewed);
        slot.register(bytes32(uint256(2)));
        assertEq(slot.attestationOf(holder), bytes32(uint256(2)));
        vm.warp(RENEWAL + 1);
        assertTrue(slot.isEligible(holder));
    }

    function test_RegisterRejects_OlderLiveAttestation_WhileNewerOneIsLive() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _issue(bytes32(uint256(2)), holder, "LE");
        slot.register(bytes32(uint256(2)));
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(
                VleiEligibility.OlderThanRegistered.selector, bytes32(uint256(1)), bytes32(uint256(2))
            )
        );
        slot.register(bytes32(uint256(1)));
        assertEq(slot.attestationOf(holder), bytes32(uint256(2)));
    }

    function test_RegisterAccepts_OlderLiveAttestation_OnceRegisteredOneIsRevoked() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _issue(bytes32(uint256(2)), holder, "LE");
        slot.register(bytes32(uint256(2)));
        eas.revoke(bytes32(uint256(2)), uint64(vm.getBlockTimestamp()));
        slot.register(bytes32(uint256(1)));
        assertTrue(slot.isEligible(holder));
    }

    function test_RegisterSameUidTwice_IsHarmless() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        slot.register(bytes32(uint256(1)));
        assertTrue(slot.isEligible(holder));
    }

    // ---- liveness: EAS semantics, not verifiedAt ----

    function test_OldVerifiedAt_DoesNotMatter() public {
        _issue(bytes32(uint256(1)), holder, "ECR");
        slot.register(bytes32(uint256(1)));
        vm.warp(RENEWAL - 1);
        assertTrue(slot.isEligible(holder));
    }

    function test_Revocation_BlocksImmediately() public {
        _issue(bytes32(uint256(1)), holder, "ECR");
        slot.register(bytes32(uint256(1)));
        eas.revoke(bytes32(uint256(1)), uint64(vm.getBlockTimestamp()));
        assertFalse(slot.isEligible(holder));
        _assertStatus(holder, IEligibility.Status.REVOKED);
        assertEq(slot.reason(holder), "vLEI attestation revoked");
    }

    function test_Expiry_BlocksAtRenewalDate() public {
        _issue(bytes32(uint256(1)), holder, "ECR");
        slot.register(bytes32(uint256(1)));
        vm.warp(RENEWAL);
        assertFalse(slot.isEligible(holder));
        _assertStatus(holder, IEligibility.Status.EXPIRED);
        assertEq(slot.reason(holder), "vLEI attestation expired (LEI not renewed)");
    }

    function test_NoExpiry_FailsClosed() public {
        Attestation memory a = _attestation(bytes32(uint256(1)), holder, "LE");
        a.expirationTime = 0;
        eas.set(a);
        _expectNotLive(bytes32(uint256(1)), "vLEI attestation has no expiry; the bridge always sets one");
        slot.register(bytes32(uint256(1)));
    }

    // ---- credential type ----

    function test_UnacceptedCredType_IsNotEligible() public {
        _issue(bytes32(uint256(1)), holder, "OOR");
        _expectNotLive(bytes32(uint256(1)), "vLEI credential type OOR is not accepted by this slot");
        slot.register(bytes32(uint256(1)));
    }

    function test_EmptyAcceptedSet_AcceptsAnyCredType() public {
        VleiEligibility any = new VleiEligibility(IEAS(address(eas)), SCHEMA, bridge, TOPIC, new string[](0));
        _issue(bytes32(uint256(1)), holder, "OOR");
        any.register(bytes32(uint256(1)));
        assertTrue(any.isEligible(holder));
    }

    // ---- IEligibility.explain: one TopicStatus on the slot's topic, never reverts ----

    function test_Explain_NotRegistered_ForUnknownWallet() public view {
        assertFalse(slot.isEligible(other));
        _assertStatus(other, IEligibility.Status.NOT_REGISTERED);
        assertEq(slot.reason(other), "no vLEI attestation registered for this wallet");
        (string memory lei,,,) = slot.identityOf(other);
        assertEq(lei, "");
    }

    function test_Explain_ReportsTheConfiguredTopic() public {
        VleiEligibility role = new VleiEligibility(IEAS(address(eas)), SCHEMA, bridge, 16, new string[](0));
        assertEq(role.topic(), 16);
        IEligibility.TopicStatus[] memory out = role.explain(other);
        assertEq(out.length, 1);
        assertEq(out[0].topic, 16);
        assertEq(uint256(out[0].status), uint256(IEligibility.Status.NOT_REGISTERED));
    }

    function test_Explain_AttesterNotTrusted_WhenRegisteredAttestationChangesAttester() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        Attestation memory a = _attestation(bytes32(uint256(1)), holder, "LE");
        a.attester = other;
        eas.set(a);
        assertFalse(slot.isEligible(holder));
        _assertStatus(holder, IEligibility.Status.ATTESTER_NOT_TRUSTED);
    }

    function test_Explain_PolicyRejected_WhenRegisteredDataTurnsMalformed() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        Attestation memory a = _attestation(bytes32(uint256(1)), holder, "LE");
        a.data = hex"deadbeef";
        eas.set(a);
        assertFalse(slot.isEligible(holder));
        _assertStatus(holder, IEligibility.Status.POLICY_REJECTED);
        assertEq(slot.reason(holder), "attestation data does not decode as the vLEI bridge schema");
    }

    function test_Explain_PolicyRejected_WhenRegisteredCredTypeStopsBeingAccepted() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        _issue(bytes32(uint256(1)), holder, "OOR"); // same UID, data rewritten in the mock
        assertFalse(slot.isEligible(holder));
        _assertStatus(holder, IEligibility.Status.POLICY_REJECTED);
    }

    // ---- identity view ----

    function test_IdentityOf_ReturnsLeiAndLegalName() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        (string memory lei, string memory name, string memory credType, uint64 exp) = slot.identityOf(holder);
        assertEq(lei, "875500ELOZEL05BVXV37");
        assertEq(name, "Global Legal Entity Identifier Foundation Singapore Branch");
        assertEq(credType, "LE");
        assertEq(exp, RENEWAL);
    }

    function test_IdentityOf_EmptyWhenNotEligible() public {
        _issue(bytes32(uint256(1)), holder, "LE");
        slot.register(bytes32(uint256(1)));
        eas.revoke(bytes32(uint256(1)), uint64(vm.getBlockTimestamp()));
        (string memory lei,,, uint64 exp) = slot.identityOf(holder);
        assertEq(lei, "");
        assertEq(exp, 0);
    }

    // ---- constructor ----

    function test_ConstructorRejects_ZeroValues() public {
        string[] memory none = new string[](0);
        vm.expectRevert(VleiEligibility.ZeroAddress.selector);
        new VleiEligibility(IEAS(address(0)), SCHEMA, bridge, TOPIC, none);
        vm.expectRevert(VleiEligibility.ZeroAddress.selector);
        new VleiEligibility(IEAS(address(eas)), SCHEMA, address(0), TOPIC, none);
        vm.expectRevert(VleiEligibility.ZeroSchema.selector);
        new VleiEligibility(IEAS(address(eas)), bytes32(0), bridge, TOPIC, none);
    }
}
