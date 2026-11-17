// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IEligibility
/// @notice The "eligibility slot" a regulated token asks before moving funds:
///         may this wallet hold the token? Mirrors the slot interface in the EEA
///         Tokenization Starter Kit build plan (finos-hack/fall-hackathon-2026-beta#1,
///         section 3.2). Implementations must never revert from these views
///         (ERC-7943 `canSend` / `canReceive` / `canTransfer` forbid it); a failure
///         is answered with `false` and a reason.
interface IEligibility {
    /// @notice True when `wallet` currently satisfies this slot's rule.
    function isEligible(address wallet) external view returns (bool);

    /// @notice Human-readable reason for the current answer, for consoles and audit
    ///         trails. "ok" prefixes a positive answer.
    function explain(address wallet) external view returns (string memory);
}
