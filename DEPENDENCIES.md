Vendored dependencies (ordinary source files; no submodules or package installation needed):

- OpenZeppelin Contracts **v5.5.0**, transitive source closure used by the application, from https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.5.0/contracts. License: `lib/openzeppelin-contracts/LICENSE` (MIT).
- forge-std **v1.9.7**, source tree from https://github.com/foundry-rs/forge-std/tree/v1.9.7/src. Licenses: `lib/forge-std/LICENSE-APACHE` and `LICENSE-MIT`.
- `src/OracleAttestation.sol`: canonical Solidity from the assignment's pinned `oracle-consumer/REFERENCE.md`, with a virtual signature-check hook extracted for bounded EOA/ERC-1271 signer grace; canonical domain, attestation layout, validity windows and replay consumption are preserved; SPDX MIT. `test/OracleConsumerConformance.t.sol` preserves the supplied protocol vector and adapts delivery to this application.

The installed Solidity compiler is toolchain infrastructure, not a repository dependency. Foundry selects version 0.8.26 from `foundry.toml`; no compiler executable is vendored or path-pinned.
