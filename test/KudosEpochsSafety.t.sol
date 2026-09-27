// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KudosEpochs} from "../src/KudosEpochs.sol";

interface ITransferCallback {
    function onTransfer() external;
}

/// @dev Test-only token. Production LaunchToken has neither transfer hooks nor these failure modes.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Revert,
        ReturnNothing
    }

    Mode public pullMode;
    Mode public pushMode;
    address public rejectedRecipient;
    address public hook;
    bool public hookPull;
    bool public hookPush;
    bool private inHook;

    error TransferRejected();

    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1000 ether);
    }

    function configureFailure(Mode pull, Mode push, address recipient) external {
        pullMode = pull;
        pushMode = push;
        rejectedRecipient = recipient;
    }

    function configureHook(address hook_, bool onPull, bool onPush) external {
        hook = hook_;
        hookPull = onPull;
        hookPush = onPush;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (pullMode == Mode.ReturnFalse) return false;
        if (pullMode == Mode.Revert) revert TransferRejected();
        if (hookPull) _callback();
        super.transferFrom(from, to, amount);
        if (pullMode == Mode.ReturnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode mode = rejectedRecipient == address(0) || to == rejectedRecipient ? pushMode : Mode.Normal;
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Revert) revert TransferRejected();
        if (hookPush) _callback();
        super.transfer(to, amount);
        if (mode == Mode.ReturnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _callback() private {
        if (!inHook) {
            inHook = true;
            ITransferCallback(hook).onTransfer();
            inHook = false;
        }
    }
}

contract ReenteringRecipient is ITransferCallback {
    KudosEpochs public immutable app;
    address public immutable token;
    address public immutable other;
    bool public withdrawSucceeded;
    bool public giveSucceeded;
    bytes public withdrawResult;
    bytes public giveResult;
    uint256 public observedCredit;
    uint256 public callbacks;

    constructor(KudosEpochs app_, address other_) {
        app = app_;
        token = address(app_.token());
        other = other_;
    }

    function collect() external {
        app.withdraw();
    }

    function onTransfer() external {
        require(msg.sender == token, "only test token");
        ++callbacks;
        observedCredit = app.withdrawable(address(this));
        (withdrawSucceeded, withdrawResult) = address(app).call(abi.encodeCall(app.withdraw, ()));
        (giveSucceeded, giveResult) = address(app).call(abi.encodeCall(app.give, (other, 1, 0)));
    }
}

contract KudosEpochsSafetyTest is Test {
    AdversarialToken private token;
    KudosEpochs private app;
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);

    function setUp() public {
        token = new AdversarialToken();
        app = new KudosEpochs(address(token));
        token.approve(address(app), type(uint256).max);
    }

    function test_falseReturningPullRevertsAllCreditsAndCounters() public {
        token.configureFailure(AdversarialToken.Mode.ReturnFalse, AdversarialToken.Mode.Normal, address(0));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        app.give(BOB, 3, 2 ether);
        _assertUncredited();
    }

    function test_revertingPullRevertsAllCreditsAndCounters() public {
        token.configureFailure(AdversarialToken.Mode.Revert, AdversarialToken.Mode.Normal, address(0));
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        app.give(BOB, 3, 2 ether);
        _assertUncredited();
    }

    function test_falseReturningWithdrawalPreservesCreditAndOtherRecipientsCanWithdraw() public {
        app.give(BOB, 2, 3 ether);
        app.give(CAROL, 1, 4 ether);
        token.configureFailure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.ReturnFalse, BOB);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(BOB);
        app.withdraw();
        assertEq(app.withdrawable(BOB), 6 ether);
        assertEq(token.balanceOf(BOB), 0);

        vm.prank(CAROL);
        app.withdraw();
        assertEq(token.balanceOf(CAROL), 4 ether);
        assertEq(token.balanceOf(address(app)), 6 ether);
        assertEq(app.withdrawable(CAROL), 0);

        token.configureFailure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, address(0));
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(BOB), 6 ether);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_revertingWithdrawalPreservesCreditForRetry() public {
        app.give(BOB, 2, 3 ether);
        token.configureFailure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Revert, BOB);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        vm.prank(BOB);
        app.withdraw();
        assertEq(app.withdrawable(BOB), 6 ether);
        assertEq(app.tipsReceived(BOB), 6 ether);
        assertEq(token.balanceOf(address(app)), 6 ether);

        token.configureFailure(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal, address(0));
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(BOB), 6 ether);
        assertEq(app.withdrawable(BOB), 0);
    }

    function test_safeERC20HandlesEmptyReturnData() public {
        token.configureFailure(AdversarialToken.Mode.ReturnNothing, AdversarialToken.Mode.ReturnNothing, address(0));
        app.give(BOB, 2, 3 ether);
        assertEq(app.withdrawable(BOB), 6 ether);
        vm.prank(BOB);
        app.withdraw();
        assertEq(token.balanceOf(BOB), 6 ether);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_freeGiveDoesNotCallToken() public {
        token.configureFailure(AdversarialToken.Mode.Revert, AdversarialToken.Mode.Revert, address(0));
        app.give(BOB, 5, 0);
        assertEq(app.receivedIn(0, BOB), 5);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_withdrawClearsCreditBeforeCallbackAndBlocksBothReentryPaths() public {
        ReenteringRecipient attacker = new ReenteringRecipient(app, CAROL);
        app.give(address(attacker), 2, 3 ether);
        app.give(BOB, 1, 4 ether);
        token.configureHook(address(attacker), false, true);
        attacker.collect();

        assertEq(attacker.callbacks(), 1);
        assertEq(attacker.observedCredit(), 0, "credit must be cleared before transfer");
        _assertBlocked(attacker);
        assertEq(app.remaining(address(attacker)), 5);
        assertEq(app.receivedIn(0, CAROL), 0);
        assertEq(app.withdrawable(address(attacker)), 0);
        assertEq(app.tipsReceived(address(attacker)), 6 ether);
        assertEq(token.balanceOf(address(attacker)), 6 ether);
        assertEq(token.balanceOf(address(app)), 4 ether);
        assertEq(app.withdrawable(BOB), 4 ether);
    }

    function test_transferFromCallbackCannotWithdrawProvisionalCreditOrGiveAgain() public {
        ReenteringRecipient attacker = new ReenteringRecipient(app, CAROL);
        token.configureHook(address(attacker), true, false);
        app.give(address(attacker), 3, 2 ether);

        assertEq(attacker.callbacks(), 1);
        assertEq(attacker.observedCredit(), 6 ether);
        _assertBlocked(attacker);
        assertEq(token.balanceOf(address(attacker)), 0);
        assertEq(token.balanceOf(address(app)), 6 ether);
        assertEq(app.withdrawable(address(attacker)), 6 ether);
        assertEq(app.receivedIn(0, address(attacker)), 3);
        assertEq(app.receivedIn(0, CAROL), 0);
        attacker.collect();
        assertEq(token.balanceOf(address(attacker)), 6 ether);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function _assertBlocked(ReenteringRecipient attacker) private view {
        assertFalse(attacker.withdrawSucceeded());
        assertFalse(attacker.giveSucceeded());
        assertEq(
            attacker.withdrawResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(attacker.giveResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _assertUncredited() private view {
        assertEq(app.remaining(address(this)), 5);
        assertEq(app.receivedIn(0, BOB), 0);
        assertEq(app.lifetimeReceived(BOB), 0);
        assertEq(app.tipsReceived(BOB), 0);
        assertEq(app.withdrawable(BOB), 0);
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.balanceOf(address(this)), 1000 ether);
    }
}
