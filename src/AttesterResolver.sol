// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SchemaResolver} from "@eas/resolver/SchemaResolver.sol";
import {IEAS, Attestation} from "@eas/IEAS.sol";

/// @title AttesterResolver
/// @notice Restricts attestations under the vLEI-to-EAS bridge schema to a single immutable bridge wallet.
contract AttesterResolver is SchemaResolver {
    address public immutable bridgeWallet;

    error UnauthorizedAttester();
    error ZeroBridgeWallet();

    constructor(IEAS eas, address _bridgeWallet) SchemaResolver(eas) {
        if (_bridgeWallet == address(0)) revert ZeroBridgeWallet();
        bridgeWallet = _bridgeWallet;
    }

    function onAttest(
        Attestation calldata attestation,
        uint256 /*value*/
    )
        internal
        view
        override
        returns (bool)
    {
        if (attestation.attester != bridgeWallet) revert UnauthorizedAttester();
        return true;
    }

    function onRevoke(
        Attestation calldata attestation,
        uint256 /*value*/
    )
        internal
        view
        override
        returns (bool)
    {
        if (attestation.attester != bridgeWallet) revert UnauthorizedAttester();
        return true;
    }
}
