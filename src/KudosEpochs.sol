// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Five nontransferable kudos per address per deployment-relative week, with optional KUDO tips.
/// @dev Configure only with LaunchToken. Accounting assumes its exact, non-rebasing ERC-20 transfers.
contract KudosEpochs is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant KUDOS_PER_EPOCH = 5;

    IERC20 public immutable token;
    uint256 public immutable deployTimestamp;

    mapping(uint256 epoch => mapping(address giver => uint256 count)) private _givenIn;
    mapping(uint256 epoch => mapping(address recipient => uint256 count)) public receivedIn;
    mapping(address recipient => uint256 count) public lifetimeReceived;
    /// @notice Lifetime tips credited in KUDO minor units, including tips already withdrawn.
    mapping(address recipient => uint256 amount) public tipsReceived;
    mapping(address recipient => uint256 amount) public withdrawable;

    error InvalidToken(address candidate);
    error InvalidRecipient(address recipient);
    error InvalidCount(uint256 requested, uint256 available);
    error NothingToWithdraw();

    /// @param tip Total tip for this give (count * tipPerKudo), in KUDO minor units.
    event Kudos(uint256 indexed epoch, address indexed from, address indexed to, uint256 count, uint256 tip);
    event Withdrawn(address indexed recipient, uint256 amount);

    /// @param token_ The separately deployed LaunchToken; no balance or approval is needed at deploy.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken(token_);
        token = IERC20(token_);
        deployTimestamp = block.timestamp;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - deployTimestamp) / EPOCH_DURATION;
    }

    function remaining(address account) public view returns (uint256) {
        return KUDOS_PER_EPOCH - _givenIn[currentEpoch()][account];
    }

    /// @notice Give count kudos; for a positive tip, first approve count * tipPerKudo KUDO.
    /// @dev All counters and credits roll back if payment fails. The shared guard also blocks token callbacks.
    function give(address to, uint256 count, uint256 tipPerKudo) external nonReentrant {
        if (to == address(0) || to == msg.sender) revert InvalidRecipient(to);
        uint256 epoch = currentEpoch();
        uint256 available = KUDOS_PER_EPOCH - _givenIn[epoch][msg.sender];
        if (count == 0 || count > available) revert InvalidCount(count, available);
        uint256 tip = count * tipPerKudo;

        _givenIn[epoch][msg.sender] += count;
        receivedIn[epoch][to] += count;
        lifetimeReceived[to] += count;
        if (tip != 0) {
            tipsReceived[to] += tip;
            withdrawable[to] += tip;
            token.safeTransferFrom(msg.sender, address(this), tip);
        }

        emit Kudos(epoch, msg.sender, to, count, tip);
    }

    /// @notice Collect all your credited tips. A failed transfer leaves the credit available for retry.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;

        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
