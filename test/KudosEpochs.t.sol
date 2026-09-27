// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KudosEpochs} from "../src/KudosEpochs.sol";

contract KudosEpochsTest is Test {
    LaunchToken private token;
    KudosEpochs private app;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);
    uint256 private constant START = 1_700_000_123;

    event Kudos(uint256 indexed epoch, address indexed from, address indexed to, uint256 count, uint256 tip);
    event Withdrawn(address indexed recipient, uint256 amount);

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        app = new KudosEpochs(address(token));
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 1000 ether);
    }

    function test_constructorAndEmptyViews() public view {
        assertEq(address(app.token()), address(token));
        assertEq(app.deployTimestamp(), START);
        assertEq(app.currentEpoch(), 0);
        assertEq(app.remaining(ALICE), 5);
        assertEq(app.receivedIn(0, BOB), 0);
        assertEq(app.lifetimeReceived(BOB), 0);
        assertEq(app.tipsReceived(BOB), 0);
        assertEq(app.withdrawable(BOB), 0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_constructorRejectsZeroAndNonContractToken() public {
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidToken.selector, address(0)));
        new KudosEpochs(address(0));
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidToken.selector, ALICE));
        new KudosEpochs(ALICE);
    }

    function test_fiveLimitAcrossSeveralGivesAndRecipients() public {
        vm.startPrank(ALICE);
        app.give(BOB, 2, 0);
        app.give(CAROL, 1, 0);
        assertEq(app.remaining(ALICE), 2);
        app.give(BOB, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, 1, 0));
        app.give(CAROL, 1, 0);
        vm.stopPrank();
        assertEq(app.remaining(ALICE), 0);
        assertEq(app.receivedIn(0, BOB), 4);
        assertEq(app.receivedIn(0, CAROL), 1);
        assertEq(app.lifetimeReceived(BOB), 4);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_eachAddressHasItsOwnAllowance() public {
        vm.prank(ALICE);
        app.give(CAROL, 5, 0);
        vm.prank(BOB);
        app.give(CAROL, 5, 0);
        assertEq(app.remaining(ALICE), 0);
        assertEq(app.remaining(BOB), 0);
        assertEq(app.receivedIn(0, CAROL), 10);
    }

    function test_exactEpochBoundaryAndRepeatedGivesInRolloverBlock() public {
        vm.warp(START + 7 days - 1);
        vm.prank(ALICE);
        app.give(BOB, 5, 0);
        assertEq(app.currentEpoch(), 0);
        assertEq(app.remaining(ALICE), 0);

        vm.warp(START + 7 days);
        assertEq(app.currentEpoch(), 1);
        assertEq(app.remaining(ALICE), 5);
        vm.startPrank(ALICE);
        app.give(BOB, 3, 0);
        app.give(BOB, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, 1, 0));
        app.give(CAROL, 1, 0);
        vm.stopPrank();
        assertEq(app.receivedIn(0, BOB), 5);
        assertEq(app.receivedIn(1, BOB), 5);
        assertEq(app.lifetimeReceived(BOB), 10);
    }

    function test_unusedKudosDoNotRollOverEvenAfterSkippedEpochs() public {
        vm.prank(ALICE);
        app.give(BOB, 1, 0);
        vm.warp(START + 28 days);
        assertEq(app.currentEpoch(), 4);
        assertEq(app.remaining(ALICE), 5);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, 6, 5));
        vm.prank(ALICE);
        app.give(BOB, 6, 0);
        assertEq(app.receivedIn(0, BOB), 1);
        assertEq(app.receivedIn(4, BOB), 0);
    }

    function test_zeroAndSelfRecipientsFailWithoutCharging() public {
        vm.startPrank(ALICE);
        token.approve(address(app), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidRecipient.selector, address(0)));
        app.give(address(0), 1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidRecipient.selector, ALICE));
        app.give(ALICE, 1, 1 ether);
        vm.stopPrank();
        assertEq(app.remaining(ALICE), 5);
        assertEq(token.allowance(ALICE, address(app)), 10 ether);
        assertEq(token.balanceOf(ALICE), 1000 ether);
    }

    function test_zeroCountAndExcessiveCountFail() public {
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, 0, 5));
        app.give(BOB, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, 6, 5));
        app.give(BOB, 6, 0);
        vm.expectRevert(abi.encodeWithSelector(KudosEpochs.InvalidCount.selector, type(uint256).max, 5));
        app.give(BOB, type(uint256).max, 0);
        vm.stopPrank();
        assertEq(app.remaining(ALICE), 5);
    }

    function test_multipleKudosTipUsesTotalAndEmitsExpectedEvent() public {
        vm.startPrank(ALICE);
        token.approve(address(app), 6 ether);
        vm.expectEmit(true, true, true, true, address(app));
        emit Kudos(0, ALICE, BOB, 3, 6 ether);
        app.give(BOB, 3, 2 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 994 ether);
        assertEq(token.balanceOf(BOB), 1000 ether);
        assertEq(token.allowance(ALICE, address(app)), 0);
        assertEq(app.withdrawable(BOB), 6 ether);
        assertEq(app.tipsReceived(BOB), 6 ether);
        assertEq(app.receivedIn(0, BOB), 3);
        _assertConservation();
    }

    function test_freeGiveEmitsZeroTipWithoutBalanceOrApproval() public {
        vm.expectEmit(true, true, true, true, address(app));
        emit Kudos(0, CAROL, BOB, 5, 0);
        vm.prank(CAROL);
        app.give(BOB, 5, 0);
        assertEq(app.receivedIn(0, BOB), 5);
        assertEq(app.tipsReceived(BOB), 0);
    }

    function test_withdrawOnlyPaysCallerAndSecondWithdrawFails() public {
        _give(ALICE, BOB, 2, 3 ether);
        _give(ALICE, CAROL, 1, 4 ether);
        vm.expectRevert(KudosEpochs.NothingToWithdraw.selector);
        vm.prank(ALICE);
        app.withdraw();

        vm.expectEmit(true, false, false, true, address(app));
        emit Withdrawn(BOB, 6 ether);
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(BOB), 1006 ether);
        assertEq(app.withdrawable(BOB), 0);
        assertEq(app.tipsReceived(BOB), 6 ether);
        assertEq(app.withdrawable(CAROL), 4 ether);
        vm.expectRevert(KudosEpochs.NothingToWithdraw.selector);
        vm.prank(BOB);
        app.withdraw();
        _assertConservation();

        vm.prank(CAROL);
        app.withdraw();
        assertEq(token.balanceOf(CAROL), 4 ether);
        _assertConservation();
    }

    function test_tipsSurviveEpochRolloverAndCanBeWithdrawnAgainAfterNewCredit() public {
        _give(ALICE, BOB, 2, 3 ether);
        vm.warp(START + 7 days);
        _give(ALICE, BOB, 1, 4 ether);
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(BOB), 1010 ether);
        assertEq(app.tipsReceived(BOB), 10 ether);
        assertEq(app.lifetimeReceived(BOB), 3);

        _give(ALICE, BOB, 1, 1 ether);
        vm.prank(BOB);
        app.withdraw();
        assertEq(app.tipsReceived(BOB), 11 ether);
        assertEq(token.balanceOf(BOB), 1011 ether);
        _assertConservation();
    }

    function test_missingOrInsufficientApprovalRollsBackAllState() public {
        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 0, 6 ether)
        );
        app.give(BOB, 3, 2 ether);
        token.approve(address(app), 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 5 ether, 6 ether)
        );
        app.give(BOB, 3, 2 ether);
        vm.stopPrank();
        _assertUntouched(ALICE, BOB);
        assertEq(token.allowance(ALICE, address(app)), 5 ether);
    }

    function test_insufficientBalanceRollsBackCountersCreditAndAllowance() public {
        vm.startPrank(ALICE);
        token.approve(address(app), 2000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1000 ether, 2000 ether)
        );
        app.give(BOB, 2, 1000 ether);
        vm.stopPrank();
        _assertUntouched(ALICE, BOB);
        assertEq(token.allowance(ALICE, address(app)), 2000 ether);
    }

    function test_tipMultiplicationOverflowFailsBeforePaymentOrCredit() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vm.prank(ALICE);
        app.give(BOB, 5, type(uint256).max / 5 + 1);
        _assertUntouched(ALICE, BOB);
    }

    function testFuzz_exactTipAccounting(uint256 count, uint256 tipPerKudo) public {
        count = bound(count, 1, 5);
        tipPerKudo = bound(tipPerKudo, 0, 200 ether);
        uint256 tip = count * tipPerKudo;
        _give(ALICE, BOB, count, tipPerKudo);
        assertEq(app.remaining(ALICE), 5 - count);
        assertEq(app.receivedIn(0, BOB), count);
        assertEq(app.lifetimeReceived(BOB), count);
        assertEq(app.withdrawable(BOB), tip);
        assertEq(app.tipsReceived(BOB), tip);
        assertEq(token.balanceOf(ALICE), 1000 ether - tip);
        _assertConservation();
    }

    function test_directDonationsDoNotCreateCreditsOrLetGiversExtractOthersTokens() public {
        token.transfer(address(app), 9 ether);
        _give(ALICE, BOB, 1, 2 ether);
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(address(app)), 9 ether);
        assertEq(app.withdrawable(BOB), 0);
        assertEq(app.tipsReceived(BOB), 2 ether);
    }

    function test_ethUnknownSelectorsAndKudosTransfersAreRejected() public {
        vm.deal(address(this), 1 ether);
        (bool receiveSuccess,) = address(app).call{value: 1}("");
        (bool fallbackSuccess,) = address(app).call(hex"deadbeef");
        (bool payableGiveSuccess,) = address(app).call{value: 1}(abi.encodeCall(app.give, (BOB, 1, 0)));
        (bool transferSuccess,) = address(app).call(abi.encodeWithSignature("transfer(address,uint256)", BOB, 1));
        assertFalse(receiveSuccess);
        assertFalse(fallbackSuccess);
        assertFalse(payableGiveSuccess);
        assertFalse(transferSuccess);
        assertEq(address(app).balance, 0);
    }

    function _give(address from, address to, uint256 count, uint256 tipPerKudo) private {
        vm.startPrank(from);
        token.approve(address(app), count * tipPerKudo);
        app.give(to, count, tipPerKudo);
        vm.stopPrank();
    }

    function _assertUntouched(address giver, address recipient) private view {
        assertEq(app.remaining(giver), 5);
        assertEq(app.receivedIn(0, recipient), 0);
        assertEq(app.lifetimeReceived(recipient), 0);
        assertEq(app.tipsReceived(recipient), 0);
        assertEq(app.withdrawable(recipient), 0);
        _assertConservation();
    }

    function _assertConservation() private view {
        assertEq(
            token.balanceOf(address(app)), app.withdrawable(ALICE) + app.withdrawable(BOB) + app.withdrawable(CAROL)
        );
    }
}
