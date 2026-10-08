# Vendored source provenance

These files are copied verbatim from pinned upstream commits. Only source subsets and licenses needed for this project's build/test tooling are included. No dependencies require downloading at build or test time.

| Directory | Upstream | Revision | Included files / license |
| --- | --- | --- | --- |
| `lib/openzeppelin-contracts` | [OpenZeppelin Contracts v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | `69c8def5f222ff96f2b5beff05dfba996368aa79` | ERC20 and its four source dependencies; MIT, `LICENSE` |
| `lib/forge-std` | [Forge Standard Library v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | `src/`; Apache-2.0 or MIT, `LICENSE-APACHE` / `LICENSE-MIT` |
| `lib/v4-core` | [Uniswap v4 core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Production `src/` excluding upstream test fixtures; source-specific BUSL-1.1 / MIT, `licenses/` |
| `lib/solmate` | [Solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol`; AGPL-3.0-only at repository level, this source SPDX is AGPL-3.0-only; `LICENSE` |

Only OpenZeppelin's ERC20 dependency is part of PSSToken. Forge Standard Library, Uniswap v4 core, and Solmate are used by local tests. In particular, PoolManager's existing protocol administration belongs to the test integration dependency; PSSToken does not inherit it or deploy another PoolManager. The solmate revision matches the v4-core pinned submodule, delivered here as ordinary files.

