# vLEI → EAS bridge: on-chain contracts

[![test](https://github.com/OnChainTrust/vlei-eas-contracts/actions/workflows/test.yml/badge.svg)](https://github.com/OnChainTrust/vlei-eas-contracts/actions/workflows/test.yml)

The Solidity side of the [OnChainTrust vLEI bridge](https://bridge.onchaintrust.org/): the EAS schema that carries a GLEIF vLEI identity to an Ethereum wallet, the resolver that pins it to one attester, and an eligibility slot that regulated-token contracts can ask "may this wallet hold this?".

Status: prototype on the Sepolia testnet. Not audited, not for production use.

## What is on Sepolia

| Item | Value |
|---|---|
| Schema | `string lei,string legalName,string credType,string keriAid,bytes32 vleiSaid,uint64 verifiedAt` |
| Schema UID | [`0x0b5f333cdb7e06e0d9f7c5fbd7a151bb0d8afbcde17017390ef73b673f841aa7`](https://sepolia.easscan.org/schema/view/0x0b5f333cdb7e06e0d9f7c5fbd7a151bb0d8afbcde17017390ef73b673f841aa7) |
| Resolver (`AttesterResolver`) | `0xbCD6D24861d467703fbF3221f526c28A1adF9D4F` |
| Attester (bridge wallet) | `0x8EF2312aB6A316a0CA9Ad90661B6bccE8A7eCdc6` |
| EAS | `0xC2679fBD37d54388Ce493F1DB75320D236e1815e` |
| `VleiEligibility` | not yet deployed; `deployments/sepolia-eligibility.json` once it is |

The bridge service (a separate, private repository) verifies the holder's vLEI credential against the GLEIF `vlei-verifier` and the GLEIF API, checks an EIP-712 signature from the wallet, and issues one revocable attestation per wallet with `expirationTime` pinned to the LEI's GLEIF renewal date. It revokes when the credential becomes invalid or the LEI reaches a terminal status, and issues a new attestation (new UID) when the LEI is renewed. `verifiedAt` is the time of the original verification and is never refreshed; liveness is EAS liveness.

## Contracts

- `src/AttesterResolver.sol`: EAS schema resolver that admits exactly one immutable attester for attest and revoke.
- `src/IEligibility.sol`: the slot interface, `isEligible(wallet)` and `explain(wallet)`. It mirrors the slot in the EEA Tokenization Starter Kit build plan ([finos-hack/fall-hackathon-2026-beta#1](https://github.com/finos-hack/fall-hackathon-2026-beta/issues/1), section 3.2) so a kit token can use it as a second slot implementation without an adapter.
- `src/VleiEligibility.sol`: the slot answered by vLEI identity. A wallet is eligible when a registered attestation is under the bridge schema, from the bridge attester, issued to that wallet, not revoked, not expired, and of a credential type this instance accepts (set in the constructor; the deploy script defaults to `LE` and `ECR`, `OOR` is opt-in). `identityOf(wallet)` returns the LEI, legal name, credential type and expiry for consoles. Views never revert.

Because EAS has no on-chain index by recipient, a wallet's attestation UID is registered once with `register(uid)`. Anyone may call it: the contract only accepts a live bridge attestation and takes the wallet from the attestation's own recipient, and while a wallet's registered attestation is still live it can only be replaced by one issued at the same time or later, so a stranger cannot downgrade a wallet. Renewal is a second `register` with the new UID.

### Using it with Shibui instead

[Shibui](https://github.com/EntEthAlliance/rnd-rwa-erc3643-eas) already decodes this schema in its `VLEIPolicy` on claim topics 15 (legal entity) and 16 (authorised role). That route goes through Shibui's `EASClaimVerifier` and trusted-attester list rather than this slot; it needs the policy's staleness check relaxed, since the bridge does not re-attest on a schedule (pull request pending).

## Build and test

```bash
foundryup
forge install
forge build
forge test
```

Solidity 0.8.24; `eas-contracts` v1.4.0 and OpenZeppelin Contracts v5.2.0 as git submodules, revisions recorded in `foundry.lock` (the interfaces compile under 0.8.24; the `EAS.sol` implementation itself pins 0.8.28, so tests use a minimal mock for `getAttestation`).

## Deploy the eligibility slot on Sepolia

```bash
forge script script/DeployEligibility.s.sol --rpc-url $RPC_URL --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY --gas-estimate-multiplier 1000
```

Any funded key may deploy it; the slot has no owner. `ELIGIBILITY_CRED_TYPES` (comma-separated, default `LE,ECR`) sets the accepted credential types; add `OOR` to admit official-role credentials. The gas multiplier is needed on Sepolia since the 2026-10-06 fork, which charges several times forge's local estimate.

## License

MIT.
