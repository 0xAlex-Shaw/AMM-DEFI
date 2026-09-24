// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

/// @title PairMath
/// @notice Constant-product swap maths for Uniswap-V2-style pairs, with the swap fee as a parameter
///         rather than a constant.
///
/// @dev The original version of this code hardcoded a 0.3% fee (`997`/`1000`) into `getAmountIn` and
///      `getAmountOut`, while the project advertised support for PancakeSwap, ApeSwap, MDEX and other
///      forks. Those forks do not all charge 0.3% — PancakeSwap has run at 0.20% and 0.25%, ApeSwap
///      at 0.20%. Against any pool whose fee differs, the hardcoded constant makes the profit
///      calculation wrong in both directions: it reports profit where none exists and rejects trades
///      that would have been profitable. For an arbitrage bot that is not a rounding error, it is the
///      core maths being wrong on most of its stated venues.
///
///      Fees here are expressed as a numerator over `FEE_DENOMINATOR`, matching Uniswap's own
///      convention: 997 is 0.30%, 998 is 0.20%, 9975/10000 is 0.25%.
library PairMath {
    uint256 internal constant FEE_DENOMINATOR = 1000;

    /// @dev Below 900 (a 10% fee) a "pair" is almost certainly not a constant-product AMM, and above
    ///      the denominator it would imply a negative fee.
    uint256 internal constant MIN_FEE_NUMERATOR = 900;

    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidFeeNumerator();
    error OutputExceedsReserves();

    /// @notice Input required to receive exactly `amountOut`, given reserves and the pool's fee.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeNumerator)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (feeNumerator < MIN_FEE_NUMERATOR || feeNumerator > FEE_DENOMINATOR) revert InvalidFeeNumerator();
        // The original relied on SafeMath to catch this; under 0.8 an unguarded `reserveOut -
        // amountOut` would panic instead of reverting with a usable reason.
        if (amountOut >= reserveOut) revert OutputExceedsReserves();

        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * feeNumerator;
        amountIn = numerator / denominator + 1;
    }

    /// @notice Output received for exactly `amountIn`, given reserves and the pool's fee.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeNumerator)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientInputAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (feeNumerator < MIN_FEE_NUMERATOR || feeNumerator > FEE_DENOMINATOR) revert InvalidFeeNumerator();

        uint256 amountInWithFee = amountIn * feeNumerator;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice True when `a0/b0 < a1/b1`, decided exactly.
    ///
    /// @dev Replaces a 255-line fixed-point `Decimal` library whose only purpose was to divide two
    ///      reserve pairs so the quotients could be compared. Cross-multiplying answers the same
    ///      question with no division and therefore no precision loss — deleting the library made
    ///      this *more* accurate, not less. Uniswap V2 reserves are `uint112`, so each product fits
    ///      comfortably in `uint256` and cannot overflow.
    function firstPriceIsLower(uint256 a0, uint256 b0, uint256 a1, uint256 b1) internal pure returns (bool) {
        return a0 * b1 < a1 * b0;
    }

    /// @notice Floor of the integer square root of `n`.
    ///
    /// @dev The original implementation was an unbounded `while (true)` Newton loop whose exit
    ///      condition was `res - xi < 1000`. Under Solidity 0.7 that subtraction wrapped silently
    ///      whenever an iteration overshot; under 0.8 the same expression panics, so a naive compiler
    ///      bump would have turned a latent bug into an on-chain revert inside an infinite loop. It
    ///      also called `assert`, which burns all remaining gas on failure.
    ///
    ///      This version seeds from the bit length so the initial guess is within a factor of two,
    ///      then runs a fixed seven iterations — each roughly doubling the correct bits, which is
    ///      more than enough for 256 bits — and finishes with a correction that guarantees the floor.
    ///      Fixed trip count means no unbounded loop and no underflow-dependent exit test.
    function sqrt(uint256 n) internal pure returns (uint256 z) {
        if (n == 0) return 0;

        unchecked {
            uint256 r = log2Floor(n);
            z = uint256(1) << ((r >> 1) + 1);
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            z = (z + n / z) >> 1;
            uint256 zd = n / z;
            if (z > zd) z = zd;
        }
    }

    /// @notice Index of the most significant set bit, i.e. `floor(log2(x))`. Reverts on zero.
    function log2Floor(uint256 x) internal pure returns (uint256 r) {
        require(x > 0, "PairMath: log2(0)");
        assembly ("memory-safe") {
            r := shl(7, lt(0xffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, shl(2, lt(0xf, shr(r, x))))
            r := or(r, shl(1, lt(0x3, shr(r, x))))
            r := or(r, lt(0x1, shr(r, x)))
        }
    }
}
