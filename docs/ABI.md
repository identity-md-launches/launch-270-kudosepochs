# Contract interface

The ABI JSON files in [abi/](abi/) are exported from Solidity 0.8.26 build
artifacts using `scripts/export_abis.py`. They are ABI arrays, including
constructors, functions, events and errors. All application integers are
`uint256`. Token amounts are in KUDO minor units (10^18 per KUDO).

## LaunchToken

`constructor()` is nonpayable and mints `10^27` minor units to `msg.sender`.
Metadata: `name() -> string` = `Kudos`, `symbol() -> string` = `KUDO`,
`decimals() -> uint8` = `18`.

| Function | Meaning |
| --- | --- |
| `totalSupply() -> uint256` | Fixed `10^27` minor units |
| `balanceOf(address) -> uint256` | Current token balance |
| `allowance(address owner, address spender) -> uint256` | Available delegated spending |
| `approve(address spender, uint256 value) -> bool` | Set caller's allowance; emits `Approval` |
| `transfer(address to, uint256 value) -> bool` | Transfer caller's tokens; emits `Transfer` |
| `transferFrom(address from, address to, uint256 value) -> bool` | Transfer using caller's allowance |

Token errors are the standard OpenZeppelin ERC-6093 insufficient-balance,
insufficient-allowance and invalid-address errors included in its JSON ABI.
An allowance of `type(uint256).max` is not reduced by `transferFrom`; finite
allowances are reduced. Clients should refresh allowance from the view, since
spending it does not emit an `Approval` event in this implementation.

## KudosEpochs

`constructor(address token_)` is nonpayable. Use the accepted LaunchToken address;
factory manifest arguments are `["$token"]`. There is no initializer.

| Function | Meaning |
| --- | --- |
| `token() -> address` | Immutable KUDO address |
| `deployTimestamp() -> uint256` | Start of epoch zero, Unix seconds |
| `EPOCH_DURATION() -> uint256` | `604800` seconds |
| `KUDOS_PER_EPOCH() -> uint256` | `5` |
| `currentEpoch() -> uint256` | Deployment-relative week, starting at zero |
| `remaining(address account) -> uint256` | Account's unspent kudos in the current epoch |
| `receivedIn(uint256 epoch, address account) -> uint256` | Kudos received in the specified epoch |
| `lifetimeReceived(address account) -> uint256` | Kudos received across all epochs |
| `tipsReceived(address account) -> uint256` | Lifetime KUDO credited, including withdrawn tips |
| `withdrawable(address account) -> uint256` | Current uncollected KUDO |
| `give(address to, uint256 count, uint256 tipPerKudo)` | Spend 1–5 remaining kudos and optionally pay `count * tipPerKudo` |
| `withdraw()` | Collect caller's entire credit to caller |

All entries except `give` and `withdraw` are views. Both actions are nonpayable
and return no value. For a positive tip, the giver calls the token's
`approve(appAddress, count * tipPerKudo)` before `give`. The app takes no permit
argument. Free kudos require neither approval nor token balance.

Events:

```solidity
event Kudos(uint256 indexed epoch, address indexed from, address indexed to, uint256 count, uint256 tip);
event Withdrawn(address indexed recipient, uint256 amount);
```

`Kudos.tip` is the **total** KUDO paid for this give, not `tipPerKudo`.
`count` is the number of kudos, not token units. Aggregate `count` by `to`,
filtered by the indexed epoch, to build the leaderboard. Aggregate `tip` only
for token-volume statistics. `Withdrawn.amount` is the collected KUDO amount;
the lifetime counters remain unchanged.

Application errors:

| Error | Cause |
| --- | --- |
| `InvalidToken(address candidate)` | Constructor received zero or an address with no code |
| `InvalidRecipient(address recipient)` | Recipient equals the giver or zero |
| `InvalidCount(uint256 requested, uint256 available)` | Zero count or count exceeds epoch allowance |
| `NothingToWithdraw()` | Caller has no credit |
| `ReentrancyGuardReentrantCall()` | Callback tried to enter either action while an action was running |
| `SafeERC20FailedOperation(address token)` | Token returned false |

Underlying ERC-20 errors, including insufficient balance/allowance, bubble up
from token calls; decode those with the LaunchToken ABI. Solidity overflow
reverts with `Panic(0x11)`. Other low-level token failures can bubble through
SafeERC20 and Address library errors included in the app JSON ABI. Every revert
leaves kudos counters, credit, balances and allowance unchanged by that call.
