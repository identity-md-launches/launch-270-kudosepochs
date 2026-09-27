// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KudosEpochs} from "../src/KudosEpochs.sol";

/// @dev An independent ledger for four actors. Only the specified give/withdraw flows move tokens.
contract KudosHandler is Test {
    LaunchToken private immutable token;
    KudosEpochs private immutable app;
    uint256 private immutable start;
    address[4] private actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDAD)];
    mapping(uint256 => mapping(address => uint256)) private given;
    mapping(uint256 => mapping(address => uint256)) private received;
    mapping(address => uint256) private lifetime;
    mapping(address => uint256) private tips;
    mapping(address => uint256) private credit;
    mapping(address => uint256) private balances;
    uint256 private deposited;
    uint256 private paid;

    constructor(LaunchToken token_, KudosEpochs app_) {
        token = token_;
        app = app_;
        start = app_.deployTimestamp();
        for (uint256 i; i < actors.length; ++i) {
            balances[actors[i]] = token_.balanceOf(actors[i]);
        }
    }

    function give(uint256 giverSeed, uint256 recipientSeed, uint256 countSeed, uint256 tipSeed) external {
        uint256 giverIndex = giverSeed % 4;
        address giver = actors[giverIndex];
        address recipient = actors[(giverIndex + 1 + recipientSeed % 3) % 4];
        uint256 epoch = _epoch();
        uint256 available = 5 - given[epoch][giver];
        if (available == 0) return;
        uint256 count = bound(countSeed, 1, available);
        uint256 tipPerKudo = bound(tipSeed, 0, balances[giver] / count);
        uint256 total = count * tipPerKudo;
        vm.startPrank(giver);
        token.approve(address(app), total);
        app.give(recipient, count, tipPerKudo);
        vm.stopPrank();

        given[epoch][giver] += count;
        received[epoch][recipient] += count;
        lifetime[recipient] += count;
        tips[recipient] += total;
        credit[recipient] += total;
        balances[giver] -= total;
        deposited += total;
        assertAccounting();
    }

    function withdraw(uint256 actorSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = credit[actor];
        if (amount == 0) {
            vm.expectRevert(KudosEpochs.NothingToWithdraw.selector);
            vm.prank(actor);
            app.withdraw();
        } else {
            vm.prank(actor);
            app.withdraw();
            credit[actor] = 0;
            balances[actor] += amount;
            paid += amount;
        }
        assertAccounting();
    }

    function advanceTime(uint256 jumpSeed, bool exactBoundary) external {
        uint256 oldEpoch = _epoch();
        uint256 next =
            exactBoundary ? start + (oldEpoch + 1) * 7 days : vm.getBlockTimestamp() + bound(jumpSeed, 0, 14 days);
        vm.warp(next);
        for (uint256 i; i < actors.length; ++i) {
            assertEq(app.receivedIn(oldEpoch, actors[i]), received[oldEpoch][actors[i]], "history changed");
        }
        assertAccounting();
    }

    function rejectExcessKudos(uint256 actorSeed, uint256 extraSeed) external {
        uint256 index = actorSeed % 4;
        address actor = actors[index];
        uint256 available = 5 - given[_epoch()][actor];
        uint256 count = available + bound(extraSeed, 1, 100);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, count, available));
        vm.prank(actor);
        app.give(actors[(index + 1) % 4], count, 0);
        assertAccounting();
    }

    function assertAccounting() public view {
        uint256 liabilities;
        uint256 totalReceived;
        uint256 totalGiven;
        uint256 epoch = _epoch();
        assertEq(app.currentEpoch(), epoch);
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(app.withdrawable(actor), credit[actor]);
            assertEq(app.tipsReceived(actor), tips[actor]);
            assertEq(app.lifetimeReceived(actor), lifetime[actor]);
            assertEq(app.receivedIn(epoch, actor), received[epoch][actor]);
            assertEq(app.remaining(actor), 5 - given[epoch][actor]);
            assertLe(given[epoch][actor], 5);
            assertEq(token.balanceOf(actor), balances[actor]);
            liabilities += app.withdrawable(actor);
            totalReceived += received[epoch][actor];
            totalGiven += given[epoch][actor];
        }
        assertEq(token.balanceOf(address(app)), liabilities, "escrow must equal all credits");
        assertEq(liabilities, deposited - paid, "no value created or lost");
        assertEq(totalReceived, totalGiven, "kudos miscounted");
        assertEq(token.totalSupply(), 1e27);
    }

    function _epoch() private view returns (uint256) {
        return (vm.getBlockTimestamp() - start) / 7 days;
    }
}

contract KudosEpochsInvariantTest is StdInvariant, Test {
    KudosHandler private handler;

    function setUp() public {
        vm.warp(1_700_000_123);
        LaunchToken token = new LaunchToken();
        KudosEpochs app = new KudosEpochs(address(token));
        token.transfer(address(0xA11CE), 1_000_000 ether);
        token.transfer(address(0xB0B), 1_000_000 ether);
        token.transfer(address(0xCA401), 1_000_000 ether);
        token.transfer(address(0xDAD), 1_000_000 ether);
        handler = new KudosHandler(token, app);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.give.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.advanceTime.selector;
        selectors[3] = handler.rejectExcessKudos.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allCreditsAreBackedAndEveryCounterMatchesTheLedger() public view {
        handler.assertAccounting();
    }
}
