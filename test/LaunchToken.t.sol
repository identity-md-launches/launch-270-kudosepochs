// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KudosEpochs} from "../src/KudosEpochs.sol";

contract FactoryHarness {
    function deploy() external returns (LaunchToken token, KudosEpochs app) {
        token = new LaunchToken();
        app = new KudosEpochs(address(token));
    }
}

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Kudos");
        assertEq(token.symbol(), "KUDO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferIsExactAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_approveAndTransferFrom() public {
        token.approve(ALICE, 10 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 4 ether));
        assertEq(token.allowance(address(this), ALICE), 6 ether);
        assertEq(token.balanceOf(BOB), 4 ether);
    }

    function test_infiniteApprovalIsPreserved() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_insufficientBalanceAndAllowanceFail() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_zeroRecipientIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noAdministrativeEntryPointsForDeployerOrOutsider() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, 1e27);
            (bool deployerSuccess,) = address(token).call(data);
            vm.prank(ALICE);
            (bool outsiderSuccess,) = address(token).call(data);
            assertFalse(deployerSuccess, signatures[i]);
            assertFalse(outsiderSuccess, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_factoryDeploymentNeedsNoInitializationOrAppFunds() public {
        FactoryHarness factory = new FactoryHarness();
        (LaunchToken deployedToken, KudosEpochs app) = factory.deploy();
        assertEq(deployedToken.balanceOf(address(factory)), 1e27);
        assertEq(deployedToken.balanceOf(address(app)), 0);
        assertEq(address(app.token()), address(deployedToken));
        assertEq(app.deployTimestamp(), block.timestamp);
        vm.prank(ALICE);
        app.give(BOB, 5, 0);
        assertEq(app.receivedIn(0, BOB), 5);
        _checkRuntime(address(deployedToken));
        _checkRuntime(address(app));
    }

    function _checkRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
            }
        }
    }
}
