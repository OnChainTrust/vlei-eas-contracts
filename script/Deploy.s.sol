// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AttesterResolver} from "../src/AttesterResolver.sol";
import {IEAS} from "@eas/IEAS.sol";
import {ISchemaRegistry} from "@eas/ISchemaRegistry.sol";

/// @dev Deploys AttesterResolver and registers the vLEI-to-EAS schema.
/// Sepolia EAS: 0xC2679fBD37d54388Ce493F1DB75320D236e1815e
/// Sepolia SchemaRegistry: 0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0
contract DeployScript is Script {
    string constant SCHEMA =
        "string lei,string legalName,string credType,string keriAid,bytes32 vleiSaid,uint64 verifiedAt";
    address constant SEPOLIA_EAS = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    address constant SEPOLIA_SCHEMA_REGISTRY = 0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0;
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;

    error WrongChain(uint256 current, uint256 expected);

    function run() external {
        // Guard: refuse to broadcast against any chain other than Sepolia.
        // The EAS + SchemaRegistry addresses above are Sepolia-specific; on
        // another chain those literals would point at unrelated code.
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid, SEPOLIA_CHAIN_ID);

        vm.startBroadcast();

        address deployer = msg.sender;
        AttesterResolver resolver = new AttesterResolver(IEAS(SEPOLIA_EAS), deployer);
        console.log("AttesterResolver deployed:", address(resolver));
        console.log("Bridge wallet (immutable):", deployer);

        bytes32 schemaUid = ISchemaRegistry(SEPOLIA_SCHEMA_REGISTRY).register(SCHEMA, resolver, true);
        console.log("Schema registered, UID:");
        console.logBytes32(schemaUid);

        vm.stopBroadcast();

        // Write deployment artifact
        string memory json = string.concat(
            "{\n",
            '  "resolverAddress": "',
            vm.toString(address(resolver)),
            '",\n',
            '  "schemaUid": "',
            vm.toString(schemaUid),
            '",\n',
            '  "deployer": "',
            vm.toString(deployer),
            '",\n',
            '  "deployedAt": "',
            vm.toString(block.timestamp),
            '"\n',
            "}\n"
        );
        vm.writeFile("deployments/sepolia.json", json);
    }
}
