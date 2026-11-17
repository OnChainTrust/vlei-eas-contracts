// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AttesterResolver} from "../src/AttesterResolver.sol";
import {IEAS, Attestation} from "@eas/IEAS.sol";

contract AttesterResolverTest is Test {
    AttesterResolver resolver;
    address constant EAS_ADDR = address(0xE4511);
    address bridgeWallet = makeAddr("bridgeWallet");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(EAS_ADDR, hex"00"); // non-empty code so resolver thinks EAS exists
        resolver = new AttesterResolver(IEAS(EAS_ADDR), bridgeWallet);
    }

    function _makeAttestation(address attester) internal view returns (Attestation memory a) {
        a.uid = bytes32(uint256(1));
        a.schema = bytes32(uint256(2));
        a.time = uint64(block.timestamp);
        a.expirationTime = 0;
        a.revocationTime = 0;
        a.refUID = bytes32(0);
        a.recipient = address(0);
        a.attester = attester;
        a.revocable = true;
        a.data = "";
    }

    function test_AttestSucceeds_WhenAttesterIsBridge() public {
        Attestation memory a = _makeAttestation(bridgeWallet);
        vm.prank(EAS_ADDR);
        bool ok = resolver.attest(a);
        assertTrue(ok);
    }

    function test_AttestReverts_WhenAttesterIsNotBridge() public {
        Attestation memory a = _makeAttestation(stranger);
        vm.prank(EAS_ADDR);
        vm.expectRevert(AttesterResolver.UnauthorizedAttester.selector);
        resolver.attest(a);
    }

    function test_RevokeSucceeds_WhenAttesterIsBridge() public {
        Attestation memory a = _makeAttestation(bridgeWallet);
        vm.prank(EAS_ADDR);
        bool ok = resolver.revoke(a);
        assertTrue(ok);
    }

    function test_RevokeReverts_WhenAttesterIsNotBridge() public {
        Attestation memory a = _makeAttestation(stranger);
        vm.prank(EAS_ADDR);
        vm.expectRevert(AttesterResolver.UnauthorizedAttester.selector);
        resolver.revoke(a);
    }

    function test_BridgeWalletIsImmutable_NoSetterExists() public view {
        assertEq(resolver.bridgeWallet(), bridgeWallet);
    }

    function test_ConstructorReverts_WhenBridgeWalletIsZero() public {
        vm.expectRevert(AttesterResolver.ZeroBridgeWallet.selector);
        new AttesterResolver(IEAS(EAS_ADDR), address(0));
    }
}
