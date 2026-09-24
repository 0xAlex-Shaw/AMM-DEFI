// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {FlashBot, OrderedReserves} from "../FlashBot.sol";
import {PairMath} from "../libraries/PairMath.sol";

/// @notice Exposes FlashBot's internal maths so it can be unit tested directly.
contract InternalFuncTest is FlashBot {
    constructor() FlashBot(address(1)) {}

    function _calcBorrowAmount(OrderedReserves memory reserves) public pure returns (uint256) {
        return calcBorrowAmount(reserves);
    }

    function _calcSolutionForQuadratic(int256 a, int256 b, int256 c) public pure returns (int256, int256) {
        return calcSolutionForQuadratic(a, b, c);
    }

    function _sqrt(uint256 n) public pure returns (uint256) {
        return PairMath.sqrt(n);
    }

    function _log2Floor(uint256 n) public pure returns (uint256) {
        return PairMath.log2Floor(n);
    }

    function _getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 feeNumerator)
        public
        pure
        returns (uint256)
    {
        return PairMath.getAmountIn(amountOut, reserveIn, reserveOut, feeNumerator);
    }

    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeNumerator)
        public
        pure
        returns (uint256)
    {
        return PairMath.getAmountOut(amountIn, reserveIn, reserveOut, feeNumerator);
    }

    function _firstPriceIsLower(uint256 a0, uint256 b0, uint256 a1, uint256 b1) public pure returns (bool) {
        return PairMath.firstPriceIsLower(a0, b0, a1, b1);
    }
}
