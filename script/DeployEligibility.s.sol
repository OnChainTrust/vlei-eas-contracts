// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VleiEligibility} from "../src/VleiEligibility.sol";
import {IEAS} from "@eas/IEAS.sol";

/// @dev Deploys a VleiEligibility slot bound to the live bridge schema and attester on Sepolia.
///      Accepted credential types come from ELIGIBILITY_CRED_TYPES (comma-separated, default "LE,ECR").
///
///      forge script script/DeployEligibility.s.sol --rpc-url $RPC_URL --broadcast \
///        --private-key $DEPLOYER_PRIVATE_KEY --gas-estimate-multiplier 1000
contract DeployEligibilityScript is Script {
    address constant SEPOLIA_EAS = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    bytes32 constant BRIDGE_SCHEMA_UID = 0x0b5f333cdb7e06e0d9f7c5fbd7a151bb0d8afbcde17017390ef73b673f841aa7;
    address constant BRIDGE_ATTESTER = 0x8EF2312aB6A316a0CA9Ad90661B6bccE8A7eCdc6;

    error WrongChain(uint256 current, uint256 expected);

    function run() external {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid, SEPOLIA_CHAIN_ID);

        string[] memory credTypes = vm.envOr("ELIGIBILITY_CRED_TYPES", ",", _defaultCredTypes());

        vm.startBroadcast();
        VleiEligibility slot = new VleiEligibility(IEAS(SEPOLIA_EAS), BRIDGE_SCHEMA_UID, BRIDGE_ATTESTER, credTypes);
        vm.stopBroadcast();

        console.log("VleiEligibility deployed:", address(slot));
        for (uint256 i = 0; i < credTypes.length; i++) {
            console.log("  accepts credType:", credTypes[i]);
        }

        string memory json = string.concat(
            "{\n",
            '  "vleiEligibility": "',
            vm.toString(address(slot)),
            '",\n',
            '  "schemaUid": "',
            vm.toString(BRIDGE_SCHEMA_UID),
            '",\n',
            '  "attester": "',
            vm.toString(BRIDGE_ATTESTER),
            '",\n',
            '  "acceptedCredTypes": "',
            _join(credTypes),
            '",\n',
            '  "deployedAt": "',
            vm.toString(block.timestamp),
            '"\n',
            "}\n"
        );
        vm.writeFile("deployments/sepolia-eligibility.json", json);
    }

    function _defaultCredTypes() internal pure returns (string[] memory t) {
        t = new string[](2);
        t[0] = "LE";
        t[1] = "ECR";
    }

    function _join(string[] memory parts) internal pure returns (string memory out) {
        for (uint256 i = 0; i < parts.length; i++) {
            out = i == 0 ? parts[i] : string.concat(out, ",", parts[i]);
        }
    }
}
