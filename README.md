# Pepelstiltskin (PSS)

`src/PSSToken.sol:PSSToken` is the only contract deployed by this project. Its constructor takes no arguments and mints exactly **1,000,000,000 PSS**, with 18 decimals (`1000000000000000000000000000` minor units), to `msg.sender`. During launch, that caller is the launch factory. There are no subsequent mints, supply-reducing burns, owner, admin, setters, upgrades, proxies, external calls, or receiver callbacks in PSS.

## Transfer and dividend rules

| Transfer | Token fee |
| --- | --- |
| From mainnet PoolManager to another address | 3%, rounded down to a PSS minor unit |
| To PoolManager, including seeding, selling, and manager self-transfers | Zero |
| All other transfers, including distributor claims and PSS dividend claims | Zero |

The fixed PoolManager address is `0x000000000004444c5dc75cB358380D2e3dE08A90`. The rule uses the ERC-20 **from** address, including for `transferFrom`, regardless of the caller. Allowances are spent against the gross amount. The address rule also taxes manager withdrawals unrelated to swaps, such as liquidity removal; the token does not inspect swap intent or pool IDs. Other pools or transfer paths do not trigger this fee.

The buyer receives the gross amount minus the fee. Fees remain as PSS in this contract. Each fee is allocated using **balances before the net buy arrives**. A new buyer earns nothing from its own purchase; an existing holder who buys earns only on its prior balance. All holders participate except the PoolManager, this token contract, and `0x000000000000000000000000000000000000dEaD`. Transfers to zero revert. Sending to the burn address locks tokens without changing total supply. The external swarm distributor is an eligible holder while it holds tokens.

Call `claimableDividends(account)` to read a whole-unit entitlement and `claim()` to receive the caller's entitlement. Anyone may also call `claimFor(account)`, which pays **only that account**, never the caller or a chosen alternate recipient. This lets keepers release dividends to the distributor or another contract without that contract calling PSS. There is no claim fee, deadline, minimum holding duration, or holder enumeration. An empty/repeated claim returns zero. A holder who sells or transfers everything retains previously earned dividends and can still claim. Receiving tokens never gives access to earlier allocated fees; claimed tokens participate in later distributions only.

Accounting uses a cumulative index scaled by `2**128`, with individual checkpoints taken before balance changes. Each checkpoint preserves fractional entitlements, even across empty claims and zero-value transfers. Global index division rounds down; the unallocated dust remains in the contract, with no recovery function. For each allocation, global dust is less than `eligibleSupply / 2**128` minor units. An individual's claim rounds down to a minor unit and keeps its fractional remainder. If no eligible balance exists before a buy, its fee is queued until a later positive-fee transfer from PoolManager has pre-existing eligible holders. That later fee and the queued fees are allocated together; an empty-float first buyer cannot immediately reclaim its own fee. Direct token donations are excluded from dividends and cannot be recovered.

Any contract holding PSS is treated as a holder. A router holding PSS when another taxed outflow occurs earns dividends; forwarding its tokens does not forward already earned dividends. `claimFor` releases those earnings to the router, whose own code determines whether it can forward them. Integrators should direct output to the intended recipient where possible, enforce slippage against the recipient's **net balance increase**, and account for the 3% deduction. Permissionless same-transaction trading and capture of later buyers' dividends remain possible: this design has no holding-period controls. A third party can also trigger a holder's payout, making the claimed tokens eligible for later fees.

Uniswap v4 ERC-6909 claims can represent output retained inside PoolManager. Minting, transferring and burning those claims do not transfer PSS and therefore pay no PSS fee. A round trip entirely through claims earns no holder dividends. Redemption that transfers PSS out of PoolManager pays the 3% fee on the amount taken, as do liquidity withdrawals and PSS LP/protocol fee collections. This follows the specified transfer-address rule; the token cannot inspect the manager's internal swaps.

## Launch parameters and precedence

The target chain is Ethereum mainnet, chain ID **1**. The manifest intentionally has no root `chainId` key; the launch service selects the chain. `notes` is a string, as required by the manifest schema.

| Manifest parameter | Value |
| --- | --- |
| Kind / token / additional contracts | `custom_token` / `PSSToken` / none |
| Constructor arguments | `[]` |
| Paired currency | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee / tick spacing | `3000` / `60` |
| Provenance sqrtPriceX96 | `125270724187523965593206900` |
| `economics.poolBps` | `9000` |
| `economics.initialMarketCapWei` | `"2500000000000000000000"` (2500 IMD in the supplied economics) |
| `economics.remainderTo` | `0x000000000000000000000000000000000000dead` |

The mandatory build specification's pool fee **3000 = 0.30%** takes precedence over the earlier 1.25% description. The token's separate buy fee remains 3%. No dynamic pool fee is requested. The provenance price assumes PSS is currency0; the launch service must derive the actual opening price from the supplied market cap, total supply, paired-currency units, and deployed currency order. It must not blindly use that provenance price for both orders.

## Deployment and operational responsibilities

The external launch factory deploys the token, receives **100%** of its supply, forwards 10% to its Merkle distributor, and seeds up to 90% through Uniswap v4's PoolManager. No swarm allocation or pool initialization is performed by the token constructor. The launch service controls the seed position and tick/liquidity rounding. The full 90% allocation transfers without tax; any unspent rounding remainder is forwarded to the explicitly supplied burn recipient so the factory retains no PSS. The distributor delivers contributor claims without token fees.

Until swarm claims leave the distributor, its balance earns dividends; before any claims, it receives the whole first buy fee (apart from rounding). Anyone can release that entitlement with `claimFor(distributor)`, including after its original allocation is exhausted. The payout adds PSS to the distributor, not to its Merkle leaves. The external distributor's handling of surplus PSS must be verified by the launch operator; PSS cannot extend a fixed Merkle allocation or give its claimants rights to that surplus. The constructor, exclusion list and swarm allocation are unchanged.

The requested **1% creator-fee routing to $SIMD** is the launchpad's responsibility, separate from this token's holder dividends and the manifest's mandatory pool fee. This repository does not deploy the launchpad, configure its revenue recipient, deduct that fee, or claim to verify its routing. The network deployer must confirm that routing on the external launchpad before release. No missing recipient address is guessed or embedded here.

Before release, the network deployer should verify the specified mainnet PoolManager and paired currency, run the factory's protected admission checks with its actual configuration, confirm the 10% distribution and 90% seed budget, confirm zero factory remainder, and exercise the intended router's net-output behavior. Source verification uses the exact pinned build and vendored sources below. Publish/verify PSSToken on Sourcify/Etherscan immediately after factory deployment. No initialization or after-launch configuration calls exist.

## Build and checks

All imported Solidity sources and their licenses are ordinary files under `lib/`; no install step, submodules, node packages, RPC, environment variables, FFI, or filesystem cheatcode permissions are needed. Foundry and solc **0.8.26** must be installed by the runner. No compiler binary is part of this repository. Compilation targets Cancun, with optimizer enabled (200 runs), IR compilation, and `bytecode_hash = "none"`.

```sh
forge build
forge test
forge fmt --check
python3 tools/check_launch.py
```

The suite covers factory/distributor transfers, taxed buys, untaxed sells, allowances, exact pre-buy pro-rata examples, claims after a full exit, permissionless payouts to contract holders, prevention of payout redirection and double claims, transfer history, fractional accrual, exclusions, no-holder queues, rounding, invalid transfers, forbidden admin selectors, and forbidden runtime opcodes. It includes 1000 fuzz cases and a stateful invariant over 256 sequences of 64 operations, mixing self-claims and third-party claims. The invariant checks supply conservation, fee/claim/donation conservation, and coverage of every holder's liability by reserves.

The offline integration tests construct vendored Uniswap v4 PoolManager code at the specified address and use a local paired-token fixture at the specified currency address. They seed a single-sided pool, buy and sell in both currency orders, check the static pool fee, and demonstrate that an underpaid sell reverts with `CurrencyNotSettled`. Test fixtures live exclusively under `test/` and are not deployment targets.

These are local tests, not a mainnet fork or the environment-driven protected harness. Live factory, distributor, initialization hook, router, pair-token behavior, and external creator-fee routing still require network deployment verification. No transactions were broadcast. Slither/Mythril and an independent security audit were not run; the contributor network's independent adversarial review remains a release responsibility.

Dependency revisions and licenses are recorded in `DEPENDENCIES.md`.
