# Kudos / KUDO

Kudos gives every address five nontransferable kudos per week, optionally accompanied
by KUDO tips. This contribution supplies the contracts, Foundry tests, vendored
dependencies and ABI exports for the `lab-kudos-epochs` launch on **Sepolia
(chain ID 11155111)**. The separate manifest and independent review assignments
precede service deployment and the later website assignment.

## Build and verify

With Foundry and Solidity **0.8.26** installed:

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

All Solidity dependencies are ordinary files in `lib/`; no package installation,
submodules, RPC, environment variables, keys, FFI or filesystem cheatcode
permissions are needed. The verifier supplies the pinned compiler offline.
`foundry.toml` enables optimization (200 runs), targets Cancun and sets
`bytecode_hash = "none"`. Dependency versions, upstream archive URLs and archive
SHA-256 digests are recorded in [docs/dependencies.json](docs/dependencies.json).
The vendored OpenZeppelin v5.0.2 source subset and forge-std v1.9.7 source retain
their upstream licenses.

The 35 tests include 256-run fuzz tests for transfers and tips, plus 128 invariant
sequences of 64 actions. A separate ledger checks every participant's balances,
credits, epoch allowances, received counts and lifetime totals across gives,
withdrawals, invalid actions and time advances. Focused tests cover the exact
weekly boundary, multiple gives in the rollover block, multiplication overflow,
insufficient approvals/balances, repeated withdrawals, false/reverting token
calls, empty return data and reentrancy into both entry points. A local factory
harness checks supply retention, constructor configuration, runtime sizes and
forbidden opcodes. Tests deploy fresh state and do not depend on execution order.

## Contract behavior

[`LaunchToken`](src/LaunchToken.sol) is an ERC-20 named **Kudos**, symbol **KUDO**,
with 18 decimals. Its nonpayable, argument-free constructor mints exactly
**1,000,000,000 KUDO (10^27 minor units)** to its deployer. There is no external
mint, burn, owner, fee, blocklist, pause or upgrade function. Transfers move exact
amounts. In a factory launch, the factory receives the supply for LP and rewards.

[`KudosEpochs`](src/KudosEpochs.sol) takes the LaunchToken address as its sole
constructor argument and stores it as immutable `token`. It rejects zero and
addresses without code. Deployment records `deployTimestamp` and requires no
tokens, approvals, initialization call or privileged account.

Epoch zero starts at deployment. The epoch is
`(block.timestamp - deployTimestamp) / 604800`; the first second at a weekly
boundary belongs to the new epoch. Each giver has five kudos per epoch, shared
across all recipients and all calls. Unused kudos expire. Receiving kudos does not
increase the recipient's giving allowance. Historical and lifetime received
counts remain queryable; kudos are counters and have no transfer operation.

`give(to, count, tipPerKudo)` rejects the caller as recipient, the zero address,
zero count and counts exceeding the current allowance. A zero tip needs neither
balance nor approval. For positive tips, approve `count * tipPerKudo` minor units
to KudosEpochs before calling; the app pulls exactly that amount using
`SafeERC20.safeTransferFrom` and credits only `to`. Checked arithmetic and failed
transfers revert the entire give, including all counters and credits.

`withdraw()` transfers the caller's entire credit to that same caller. No one can
collect for another address or redirect a payout. Empty/repeated withdrawals
revert. Credits are cleared before `SafeERC20.safeTransfer`; a failed transfer
restores the credit for retry. Both state-changing entry points share a
reentrancy guard. `tipsReceived` is cumulative lifetime KUDO credited, so
withdrawing never decreases it. Credits persist across epoch boundaries.

For all successful give/withdraw sequences, the KUDO escrow balance equals the
sum of all withdrawable credits. ERC-20 tokens can also be sent directly to any
contract: direct donations do **not** create credits and remain unrecoverable.
With such donations, the balance is greater than or equal to the credits. There
is no sweep or rescue function. Contract recipients must be able to initiate
their own `withdraw()`; otherwise their tips remain locked. Choose the recipient
carefully, including when giving to the app itself.

All app functions are nonpayable or views, with no receive/fallback handler.
Ordinary ETH transfers fail. EVM-forced ETH cannot be prevented; any such ETH has
no app purpose or recovery path. The app has no owner, admin, pause, upgrade,
oracle, randomness, keeper or payout queue. Epoch changes are computed on demand.

Kudos counts are free and therefore **sybil-able**. Extra wallets can inflate
counts, but each tip moves only its giver's own KUDO. Sybils cannot extract other
users' KUDO. Lifetime tip volume can also reflect repeated circulation of the
same tokens; it is not a measure of unique wealth or identity.

## Deployment parameters and responsibilities

| Item | Required value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Launch kind | `evm_project` |
| Launch token | `src/LaunchToken.sol:LaunchToken`, constructor arguments `[]` |
| Sole application | `src/KudosEpochs.sol:KudosEpochs` |
| Application constructor | One `address`; manifest `constructorArgs: ["$token"]` |
| Dependency order | Deploy LaunchToken before KudosEpochs |
| ETH sent during construction | `0` for both contracts |
| Initial app KUDO balance | `0` |
| Owner or other privileged roles | None |
| Epoch length / allowance | `604800` seconds / `5` kudos per address per epoch |

The constructor validates that the token is a contract, not that arbitrary code
is the approved KUDO implementation. The manifest and deployment services must
link the accepted LaunchToken artifact through `$token`. Accounting relies on
that exact fixed-supply, non-rebasing, fee-free token. Other ERC-20 economics or
malicious replacements are unsupported. The adversarial token exists only in
tests to exercise failure paths and callbacks.

The manifest contributor writes `launch.json` from accepted source. The
independent reviewer inspects both source and that manifest, including concrete
constructor linkage and authorization. They should attempt excess kudos in the
rollover block, overflow/mis-crediting of tips, and reentrant withdrawals. These
local tests are author verification, not an independent security review or
deployment approval. Signed artifact linkage, policy, source publication,
attestation, admission, pool/reward parameters and deployment belong to services;
their later outcomes are not prerequisites of this source contribution.

Services enforce Sepolia, deploy through ProjectFactory, then record the actual
addresses, transaction and deployment block for the website. The contracts do
not impose a chain-ID gate, so the same source can be tested locally. No live
deployment address is asserted here. There are no contributor-side broadcasts
or wallet scripts.

## Website handoff and ABI

The later one-page website uses the live deployment and exports `dist/index.html`.
It reads the working currency from `KudosEpochs.token()`, shows the connected
wallet's KUDO balance, allowance, remaining kudos and withdrawable balance, and
provides Approve before every paying action, Give and Withdraw. Users acquire
KUDO by swapping Sepolia ETH in the factory-seeded launch pool; there is no
in-page swap. Github publication and IPFS hosting are approved in the workflow.

The epoch leaderboard is derived by summing `Kudos.count` by recipient for the
current epoch from deployment onward, using RPC event queries and contract views
only, with no backend or indexer. Events include indexed epoch/from/to fields.
The website must handle RPC log pagination, chain selection and reorgs, and
refresh allowance/epoch after transaction confirmation. Integer token amounts
use 18 decimals, never floating-point arithmetic.

See [docs/ABI.md](docs/ABI.md) for signatures, events, errors and client semantics.
Machine-readable exports are [LaunchToken.json](docs/abi/LaunchToken.json) and
[KudosEpochs.json](docs/abi/KudosEpochs.json). Regenerate after source changes with
`python3 scripts/export_abis.py`; use `--check` to detect stale exports.
