// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IEAS, Attestation} from "@eas/IEAS.sol";
import {IEligibility} from "./IEligibility.sol";

/// @title VleiEligibility
/// @notice An eligibility slot answered by GLEIF vLEI identity: a wallet is eligible
///         when it holds a live attestation from the vLEI-to-EAS bridge whose
///         credential type is accepted by this instance.
///
/// @dev Reads the bridge schema
///        string lei, string legalName, string credType, string keriAid,
///        bytes32 vleiSaid, uint64 verifiedAt
///      directly from EAS. Liveness is EAS liveness: the bridge issues every
///      attestation with `expirationTime` pinned to the LEI's GLEIF renewal date and
///      revokes it when the credential or the LEI stops being valid. `verifiedAt` is
///      the time of the original verification and is deliberately not used as a
///      freshness signal.
///
///      EAS keeps no on-chain index by recipient, so a wallet's attestation UID has
///      to be registered once. Anyone may register a UID: the contract checks that it
///      is a live bridge attestation issued to that recipient, and while the wallet's
///      registered attestation is still live it can only be replaced by one issued at
///      the same time or later. So the only thing a stranger can do is point a wallet
///      at a newer valid attestation of its own.
contract VleiEligibility is IEligibility {
    IEAS public immutable eas;
    bytes32 public immutable schemaUid;
    address public immutable attester;

    /// @dev keccak256 of each accepted credType ("LE", "ECR", "OOR"). Empty set = any.
    mapping(bytes32 => bool) private _acceptedCredType;
    uint256 public immutable acceptedCredTypeCount;

    /// @notice The attestation UID registered for a wallet (zero = none).
    mapping(address => bytes32) public attestationOf;

    event AttestationRegistered(address indexed wallet, bytes32 indexed uid, bytes32 indexed previousUid);

    error ZeroAddress();
    error ZeroSchema();
    error NotLiveBridgeAttestation(bytes32 uid, string reason);
    error OlderThanRegistered(bytes32 uid, bytes32 registeredUid);

    constructor(IEAS eas_, bytes32 schemaUid_, address attester_, string[] memory acceptedCredTypes) {
        if (address(eas_) == address(0) || attester_ == address(0)) revert ZeroAddress();
        if (schemaUid_ == bytes32(0)) revert ZeroSchema();
        eas = eas_;
        schemaUid = schemaUid_;
        attester = attester_;
        for (uint256 i = 0; i < acceptedCredTypes.length; i++) {
            _acceptedCredType[keccak256(bytes(acceptedCredTypes[i]))] = true;
        }
        acceptedCredTypeCount = acceptedCredTypes.length;
    }

    // ============ Registration ============

    /// @notice Point the attestation's recipient at `uid`. Reverts unless `uid` is a
    ///         live bridge attestation under this slot's schema and attester, or if the
    ///         recipient's registered attestation is still live and was issued later
    ///         than `uid`. Called by the bridge after issuance, by the holder, or by
    ///         anyone else.
    function register(bytes32 uid) external {
        Attestation memory att = eas.getAttestation(uid);
        (bool live, string memory reason) = _check(att, att.recipient);
        if (!live) revert NotLiveBridgeAttestation(uid, reason);
        bytes32 previous = attestationOf[att.recipient];
        if (previous != bytes32(0) && previous != uid) {
            Attestation memory prev = eas.getAttestation(previous);
            (bool prevLive,) = _check(prev, att.recipient);
            if (prevLive && att.time < prev.time) revert OlderThanRegistered(uid, previous);
        }
        attestationOf[att.recipient] = uid;
        emit AttestationRegistered(att.recipient, uid, previous);
    }

    // ============ IEligibility ============

    /// @inheritdoc IEligibility
    function isEligible(address wallet) external view override returns (bool) {
        bytes32 uid = attestationOf[wallet];
        if (uid == bytes32(0)) return false;
        (bool ok,) = _check(eas.getAttestation(uid), wallet);
        return ok;
    }

    /// @inheritdoc IEligibility
    function explain(address wallet) external view override returns (string memory) {
        bytes32 uid = attestationOf[wallet];
        if (uid == bytes32(0)) return "no vLEI attestation registered for this wallet";
        (, string memory reason) = _check(eas.getAttestation(uid), wallet);
        return reason;
    }

    // ============ Identity ============

    /// @notice The legal entity behind an eligible wallet, for consoles and audit trails.
    ///         Empty strings when the wallet is not currently eligible.
    function identityOf(address wallet)
        external
        view
        returns (string memory lei, string memory legalName, string memory credType, uint64 expiresAt)
    {
        bytes32 uid = attestationOf[wallet];
        if (uid == bytes32(0)) return ("", "", "", 0);
        Attestation memory att = eas.getAttestation(uid);
        (bool ok,) = _check(att, wallet);
        if (!ok) return ("", "", "", 0);
        // `_check` has already decoded `att.data` successfully, so this cannot revert.
        (lei, legalName, credType,,,) = abi.decode(att.data, (string, string, string, string, bytes32, uint64));
        expiresAt = att.expirationTime;
    }

    /// @notice ABI-decodes bridge attestation data. External so the views above can
    ///         `try` it and answer `false` instead of reverting on malformed data.
    function decode(bytes calldata data)
        external
        pure
        returns (
            string memory lei,
            string memory legalName,
            string memory credType,
            string memory keriAid,
            bytes32 vleiSaid,
            uint64 verifiedAt
        )
    {
        return abi.decode(data, (string, string, string, string, bytes32, uint64));
    }

    // ============ Internal ============

    function _check(Attestation memory att, address wallet) internal view returns (bool, string memory) {
        if (att.uid == bytes32(0)) return (false, "attestation not found on EAS");
        if (att.schema != schemaUid) return (false, "attestation is not under the vLEI bridge schema");
        if (att.attester != attester) return (false, "attestation was not issued by the vLEI bridge");
        if (att.recipient != wallet) return (false, "attestation was issued to a different wallet");
        if (att.revocationTime != 0) return (false, "vLEI attestation revoked");
        if (att.expirationTime == 0) return (false, "vLEI attestation has no expiry; the bridge always sets one");
        // Expiry is a calendar date (the LEI renewal date); validator drift of a few
        // seconds is irrelevant here.
        // forge-lint: disable-next-line(block-timestamp)
        if (att.expirationTime <= block.timestamp) return (false, "vLEI attestation expired (LEI not renewed)");

        string memory lei;
        string memory legalName;
        string memory credType;
        try this.decode(att.data) returns (
            string memory lei_, string memory legalName_, string memory credType_, string memory, bytes32, uint64
        ) {
            lei = lei_;
            legalName = legalName_;
            credType = credType_;
        } catch {
            return (false, "attestation data does not decode as the vLEI bridge schema");
        }

        if (acceptedCredTypeCount != 0 && !_acceptedCredType[keccak256(bytes(credType))]) {
            return (false, string.concat("vLEI credential type ", credType, " is not accepted by this slot"));
        }
        return (true, string.concat("ok: ", credType, " credential of ", legalName, " (LEI ", lei, ")"));
    }
}
