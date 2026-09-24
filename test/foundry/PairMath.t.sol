// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PairMath} from "../../contracts/libraries/PairMath.sol";
import {PairMathHarness} from "./PairMathHarness.sol";

/// @notice Tests for the maths extracted out of FlashBot, concentrating on the three defects the
///         migration was supposed to fix. Each test states which one it covers.
contract PairMathTest is Test {
    PairMathHarness internal harness = new PairMathHarness();

    /*//////////////////////////////////////////////////////////////
              DEFECT 1 — the swap fee was hardcoded to 0.30%
    //////////////////////////////////////////////////////////////*/

    /// @dev The original `getAmountOut` multiplied by a literal 997. This shows why that is not a
    ///      rounding detail: against a 0.20% pool the hardcoded value misprices the trade, and the
    ///      error is far larger than any tolerance an arbitrage decision could absorb.
    function test_hardcodedFeeMispricesNonDefaultPools() public pure {
        uint256 reserveIn = 1_000_000e18;
        uint256 reserveOut = 2_000_000e18;
        uint256 amountIn = 10_000e18;

        uint256 assuming030 = PairMath.getAmountOut(amountIn, reserveIn, reserveOut, 997); // Uniswap V2
        uint256 actual020 = PairMath.getAmountOut(amountIn, reserveIn, reserveOut, 998); // ApeSwap

        assertLt(assuming030, actual020, "a lower fee must return more output");

        // The pool really pays `actual020`; the old code predicted `assuming030` and would have
        // under-estimated the proceeds of every leg executed against such a pool.
        uint256 errorBps = ((actual020 - assuming030) * 10_000) / actual020;
        assertGe(errorBps, 9, "error should be around a basis point of notional, not noise");
    }

    /// @dev Same argument on the input side, which is where the debt owed to the flash-swap pool is
    ///      computed. Under-quoting the debt is the direction that makes a transaction revert.
    function test_feeAffectsRequiredInput() public pure {
        uint256 in030 = PairMath.getAmountIn(10_000e18, 1_000_000e18, 2_000_000e18, 997);
        uint256 in020 = PairMath.getAmountIn(10_000e18, 1_000_000e18, 2_000_000e18, 998);
        assertGt(in030, in020, "a higher fee must demand more input");
    }

    function test_feeNumeratorIsValidated() public {
        vm.expectRevert(PairMath.InvalidFeeNumerator.selector);
        harness.getAmountOut(1e18, 1e21, 1e21, 899); // implausibly large fee

        vm.expectRevert(PairMath.InvalidFeeNumerator.selector);
        harness.getAmountOut(1e18, 1e21, 1e21, 1001); // negative fee
    }

    /// @dev Under 0.8 an unguarded `reserveOut - amountOut` panics. The original relied on SafeMath
    ///      for this; the rewrite returns a named error instead of a bare arithmetic panic.
    function test_outputExceedingReservesRevertsCleanly() public {
        vm.expectRevert(PairMath.OutputExceedsReserves.selector);
        harness.getAmountIn(1_000e18, 1e21, 1_000e18, 997);
    }

    /// @dev Swapping in and straight back out must never be profitable at any valid fee — the basic
    ///      sanity property of a constant-product pool. Catches sign and inversion errors.
    function testFuzz_roundTripNeverProfits(uint256 amountIn, uint256 r0, uint256 r1, uint16 fee) public pure {
        r0 = bound(r0, 1e18, 1e30);
        r1 = bound(r1, 1e18, 1e30);
        amountIn = bound(amountIn, 1e6, r0 / 10);
        uint256 feeNumerator = bound(fee, PairMath.MIN_FEE_NUMERATOR, PairMath.FEE_DENOMINATOR);

        uint256 out = PairMath.getAmountOut(amountIn, r0, r1, feeNumerator);
        vm.assume(out > 0 && out < r1);
        uint256 back = PairMath.getAmountOut(out, r1 - out, r0 + amountIn, feeNumerator);
        assertLe(back, amountIn, "round trip produced free money");
    }

    /// @dev `getAmountIn` is the inverse of `getAmountOut`, up to its deliberate +1 rounding in the
    ///      pool's favour.
    function testFuzz_getAmountInInvertsGetAmountOut(uint256 amountOut, uint256 r0, uint256 r1, uint16 fee)
        public
        pure
    {
        r0 = bound(r0, 1e18, 1e30);
        r1 = bound(r1, 1e18, 1e30);
        amountOut = bound(amountOut, 1e6, r1 / 10);
        uint256 feeNumerator = bound(fee, PairMath.MIN_FEE_NUMERATOR, PairMath.FEE_DENOMINATOR);

        uint256 needed = PairMath.getAmountIn(amountOut, r0, r1, feeNumerator);
        uint256 got = PairMath.getAmountOut(needed, r0, r1, feeNumerator);
        assertGe(got, amountOut, "paying the quoted input must cover the requested output");
    }

    /*//////////////////////////////////////////////////////////////
                    DEFECT 2 — sqrt underflowed its exit test
    //////////////////////////////////////////////////////////////*/

    function test_sqrtKnownValues() public pure {
        assertEq(PairMath.sqrt(0), 0);
        assertEq(PairMath.sqrt(1), 1);
        assertEq(PairMath.sqrt(4), 2);
        assertEq(PairMath.sqrt(8), 2);
        assertEq(PairMath.sqrt(9), 3);
        assertEq(PairMath.sqrt(1e18), 1e9);
        assertEq(PairMath.sqrt(type(uint256).max), 340_282_366_920_938_463_463_374_607_431_768_211_455);
    }

    /// @dev The original `assert(n > 1)` burned all gas for n of 0 or 1, and its `while (true)` loop
    ///      exited on `res - xi < 1000`, which under 0.8 panics whenever an iteration overshoots.
    ///      These are precisely the inputs that exercised that path.
    function test_sqrtHandlesTheInputsTheOldOneRejected() public pure {
        assertEq(PairMath.sqrt(0), 0);
        assertEq(PairMath.sqrt(1), 1);
        assertEq(PairMath.sqrt(2), 1);
        assertEq(PairMath.sqrt(3), 1);
    }

    /// @dev The defining property, over the whole uint256 range. The old implementation returned a
    ///      deliberately imprecise result ("don't need be too precise to save gas") divided by 1e3,
    ///      so it could not satisfy this.
    function testFuzz_sqrtIsExactFloor(uint256 n) public pure {
        uint256 z = PairMath.sqrt(n);
        assertLe(z * z, n, "z^2 > n");
        if (z < type(uint128).max) {
            assertGt((z + 1) * (z + 1), n, "(z+1)^2 <= n");
        }
    }

    function testFuzz_log2FloorBrackets(uint256 x) public pure {
        vm.assume(x > 0);
        uint256 r = PairMath.log2Floor(x);
        assertGe(x, uint256(1) << r);
        if (r < 255) assertLt(x, uint256(1) << (r + 1));
    }

    /*//////////////////////////////////////////////////////////////
          DEFECT 3 — 255 lines of Decimal existed to compare prices
    //////////////////////////////////////////////////////////////*/

    function test_priceComparisonKnownCases() public pure {
        // 1/2 < 1/1
        assertTrue(PairMath.firstPriceIsLower(1e18, 2e18, 1e18, 1e18));
        // 1/1 is not lower than 1/2
        assertFalse(PairMath.firstPriceIsLower(1e18, 1e18, 1e18, 2e18));
        // equal prices are not strictly lower, in either direction
        assertFalse(PairMath.firstPriceIsLower(1e18, 2e18, 2e18, 4e18));
        assertFalse(PairMath.firstPriceIsLower(2e18, 4e18, 1e18, 2e18));
    }

    /// @dev Cross-multiplication agrees with the quotient comparison the `Decimal` library performed,
    ///      and is exact where that one truncated. Uniswap V2 reserves are uint112, so this covers
    ///      the full realistic domain without overflow.
    function testFuzz_priceComparisonMatchesQuotients(uint112 a0, uint112 b0, uint112 a1, uint112 b1) public pure {
        vm.assume(a0 > 0 && b0 > 0 && a1 > 0 && b1 > 0);
        bool exact = PairMath.firstPriceIsLower(a0, b0, a1, b1);
        // Reference: the same question asked with 18-decimal fixed point, as Decimal.div did.
        uint256 p0 = (uint256(a0) * 1e18) / b0;
        uint256 p1 = (uint256(a1) * 1e18) / b1;
        if (p0 != p1) {
            assertEq(exact, p0 < p1, "exact comparison disagrees with the fixed-point one");
        }
        // Where the fixed-point quotients tie, the exact comparison may still resolve the ordering --
        // that is the precision the old Decimal-based path silently discarded.
    }

    function testFuzz_priceComparisonIsAntisymmetric(uint112 a0, uint112 b0, uint112 a1, uint112 b1) public pure {
        vm.assume(a0 > 0 && b0 > 0 && a1 > 0 && b1 > 0);
        bool forward = PairMath.firstPriceIsLower(a0, b0, a1, b1);
        bool reverse = PairMath.firstPriceIsLower(a1, b1, a0, b0);
        assertFalse(forward && reverse, "both orderings cannot be strictly lower");
    }
}
