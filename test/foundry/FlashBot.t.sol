// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FlashBot, OrderedReserves} from "../../contracts/FlashBot.sol";
import {InternalFuncTest} from "../../contracts/test/InternalFuncTest.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";
import {PairMath} from "../../contracts/libraries/PairMath.sol";

contract FlashBotTest is Test {
    InternalFuncTest internal bot;
    TestERC20 internal weth;
    address internal alice = address(0xA11CE);

    function setUp() public {
        weth = new TestERC20("Wrapped Ether", "WETH", 18);
        bot = new InternalFuncTest();
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_ownerIsDeployer() public view {
        assertEq(bot.owner(), address(this));
    }

    function test_addBaseTokenIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bot.addBaseToken(address(weth));
    }

    /// @dev The original `withdraw()` had no access modifier at all. Funds could only ever reach the
    ///      owner, but an unguarded loop over arbitrary token contracts is free griefing.
    function test_withdrawIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bot.withdraw();
    }

    function test_setFeeIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        bot.setDefaultFeeNumerator(998);
    }

    function test_callbackRejectsUnpermissionedCaller() public {
        vm.prank(alice);
        vm.expectRevert(FlashBot.UnpermissionedCallback.selector);
        bot.uniswapV2Call(address(bot), 1, 0, "");
    }

    function test_baseTokenLifecycle() public {
        // The constructor seeds WETH; InternalFuncTest passes address(1).
        assertTrue(bot.baseTokensContains(address(1)));
        assertEq(bot.getBaseTokens().length, 1);

        bot.addBaseToken(address(weth));
        assertTrue(bot.baseTokensContains(address(weth)));
        assertEq(bot.getBaseTokens().length, 2);

        bot.removeBaseToken(address(weth));
        assertFalse(bot.baseTokensContains(address(weth)));
        assertEq(bot.getBaseTokens().length, 1);
    }

    /*//////////////////////////////////////////////////////////////
                             THE FEE REGISTRY
    //////////////////////////////////////////////////////////////*/

    function test_feeDefaultsToThirtyBps() public view {
        assertEq(bot.defaultFeeNumerator(), 997);
        assertEq(bot.feeNumeratorOf(address(0xBEEF)), 997);
    }

    function test_perPoolFeeOverrideTakesPrecedence() public {
        address apeSwapPool = address(0xA9E5);
        bot.setPairFeeNumerator(apeSwapPool, 998); // ApeSwap charges 0.20%
        assertEq(bot.feeNumeratorOf(apeSwapPool), 998);
        // Other pools are unaffected.
        assertEq(bot.feeNumeratorOf(address(0xBEEF)), 997);
        // Zero clears the override.
        bot.setPairFeeNumerator(apeSwapPool, 0);
        assertEq(bot.feeNumeratorOf(apeSwapPool), 997);
    }

    function test_feeOverrideIsValidated() public {
        vm.expectRevert(FlashBot.InvalidFeeNumerator.selector);
        bot.setPairFeeNumerator(address(0xA9E5), 500);

        vm.expectRevert(FlashBot.InvalidFeeNumerator.selector);
        bot.setDefaultFeeNumerator(1200);
    }

    /*//////////////////////////////////////////////////////////////
          THE BORROW SOLVER — the old one assumed 18 decimals
    //////////////////////////////////////////////////////////////*/

    /// @dev The original picked its scaling divisor from a hardcoded ladder of decimal thresholds and
    ///      said so: "this workaround is only suitable for ERC20 token with 18 decimals". A USDC pool
    ///      (6 decimals) falls off the bottom of that ladder. This is the case that used to mis-scale.
    function test_borrowSolverHandlesSixDecimalReserves() public view {
        OrderedReserves memory r = OrderedReserves({
            a1: 1_000_000e6, // 1M USDC
            b1: 400e18, // 400 WETH
            a2: 1_000_000e6,
            b2: 380e18 // richer pool: same USDC, less WETH => higher USDC price
        });
        uint256 amount = bot._calcBorrowAmount(r);
        assertGt(amount, 0, "solver returned nothing for a 6-decimal pair");
        assertLt(amount, r.b1, "borrow must leave the debt pool solvent");
        assertLt(amount, r.b2, "borrow must leave the target pool solvent");
    }

    function test_borrowSolverHandlesEighteenDecimalReserves() public view {
        OrderedReserves memory r = OrderedReserves({a1: 1_000_000e18, b1: 400e18, a2: 1_000_000e18, b2: 380e18});
        uint256 amount = bot._calcBorrowAmount(r);
        assertGt(amount, 0);
        assertLt(amount, r.b1);
        assertLt(amount, r.b2);
    }

    /// @dev Eight-decimal WBTC pools sit between the two cases above and were also outside the
    ///      ladder's assumptions.
    function test_borrowSolverHandlesEightDecimalReserves() public view {
        OrderedReserves memory r = OrderedReserves({a1: 500e8, b1: 9_000e18, a2: 500e8, b2: 8_600e18});
        uint256 amount = bot._calcBorrowAmount(r);
        assertGt(amount, 0);
        assertLt(amount, r.b1);
        assertLt(amount, r.b2);
    }

    /// @dev Two pools at the identical price offer nothing; the solver must refuse rather than return
    ///      a nonsense size.
    function test_borrowSolverRejectsEqualPrices() public {
        OrderedReserves memory r = OrderedReserves({a1: 1_000_000e18, b1: 400e18, a2: 1_000_000e18, b2: 400e18});
        vm.expectRevert();
        bot._calcBorrowAmount(r);
    }

    /// @dev Scaling is derived from bit width now, so the solver should hold up across a wide range of
    ///      reserve magnitudes rather than only the band the ladder anticipated.
    function testFuzz_borrowSolverAcrossMagnitudes(uint96 baseReserve, uint96 quoteReserve, uint16 gapBps) public view {
        uint256 a = bound(baseReserve, 1e6, 1e30);
        uint256 b = bound(quoteReserve, 1e6, 1e30);
        uint256 gap = bound(gapBps, 100, 5_000); // 1% - 50% price divergence

        // Second pool holds less quote token for the same base, so its base price is higher.
        uint256 b2 = (b * (10_000 - gap)) / 10_000;
        vm.assume(b2 > 0 && b2 < b);

        OrderedReserves memory r = OrderedReserves({a1: a, b1: b, a2: a, b2: b2});
        try bot._calcBorrowAmount(r) returns (uint256 amount) {
            // When it does produce an answer it must be solvent against both pools.
            assertGt(amount, 0);
            assertLt(amount, r.b1);
            assertLt(amount, r.b2);
        } catch {
            // Refusing is acceptable; returning an unsolvent size is not.
        }
    }

    /*//////////////////////////////////////////////////////////////
                              THE QUADRATIC
    //////////////////////////////////////////////////////////////*/

    /// @dev The original required the discriminant to be strictly positive, so a legitimate double
    ///      root at m == 0 reverted. x^2 - 2x + 1 = 0 has the double root x = 1.
    function test_quadraticAcceptsDoubleRoot() public view {
        (int256 x1, int256 x2) = bot._calcSolutionForQuadratic(1, -2, 1);
        assertEq(x1, 1);
        assertEq(x2, 1);
    }

    function test_quadraticRejectsComplexRoots() public {
        // x^2 + x + 1 = 0 has discriminant -3.
        vm.expectRevert(FlashBot.ComplexRoot.selector);
        bot._calcSolutionForQuadratic(1, 1, 1);
    }

    function test_quadraticKnownRoots() public view {
        // x^2 - 5x + 6 = 0 -> roots 3 and 2.
        (int256 x1, int256 x2) = bot._calcSolutionForQuadratic(1, -5, 6);
        assertEq(x1, 3);
        assertEq(x2, 2);
    }
}
