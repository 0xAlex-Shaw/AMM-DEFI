// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {PairMath} from "../../contracts/libraries/PairMath.sol";

/// @notice External wrapper so revert-expectation cheatcodes can observe library reverts, which are
///         otherwise inlined into the calling test contract and never cross a call boundary.
contract PairMathHarness {
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint256 fee)
        external
        pure
        returns (uint256)
    {
        return PairMath.getAmountIn(amountOut, reserveIn, reserveOut, fee);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 fee)
        external
        pure
        returns (uint256)
    {
        return PairMath.getAmountOut(amountIn, reserveIn, reserveOut, fee);
    }

    function log2Floor(uint256 x) external pure returns (uint256) {
        return PairMath.log2Floor(x);
    }
}
