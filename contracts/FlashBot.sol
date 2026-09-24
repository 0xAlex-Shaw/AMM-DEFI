// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {PairMath} from "./libraries/PairMath.sol";

struct OrderedReserves {
    uint256 a1; // base asset reserve of the lower-priced pool
    uint256 b1; // quote asset reserve of the lower-priced pool
    uint256 a2; // base asset reserve of the higher-priced pool
    uint256 b2; // quote asset reserve of the higher-priced pool
}

struct ArbitrageInfo {
    address baseToken;
    address quoteToken;
    bool baseTokenSmaller;
    address lowerPool; // pool with lower price, denominated in quote asset
    address higherPool; // pool with higher price, denominated in quote asset
}

struct CallbackData {
    address debtPool;
    address targetPool;
    bool debtTokenSmaller;
    address borrowedToken;
    address debtToken;
    uint256 debtAmount;
    uint256 debtTokenOutAmount;
}

/// @title FlashBot
/// @notice Atomic arbitrage between two Uniswap-V2-style pools holding the same token pair, funded by
///         a flash swap so the position is never open across transactions.
///
/// @dev Derived from `paco0x/amm-arbitrageur`, originally authored by Penghui Liao and contributors
///      and released under the WTFPL. This revision migrates the contract from Solidity 0.7.6 to
///      0.8.28 and fixes several defects present in the original; each is documented at the site of
///      the change. Summary:
///
///        * The swap fee was hardcoded to 0.30% while the project advertised support for forks that
///          charge other rates, making the profit maths wrong on most of its stated venues. Fees are
///          now tracked per pool. See {PairMath} and {feeNumeratorOf}.
///        * `sqrt` was an unbounded Newton loop whose exit test underflowed. See {PairMath.sqrt}.
///        * A 255-line fixed-point `Decimal` library existed only to divide reserves so quotients
///          could be compared; cross-multiplication is exact. See {PairMath.firstPriceIsLower}.
///        * `hardhat/console.sol` was imported into the deployed contract.
///        * ETH was returned with `.transfer`, whose 2300 gas stipend fails for contract owners.
///        * `withdraw()` was unguarded and reverted wholesale if any single base token reverted.
///        * The borrow-amount solver assumed 18-decimal tokens. See {calcBorrowAmount}.
contract FlashBot is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Only this address may invoke the flash-swap callback. `address(1)` is the inert sentinel.
    ///
    ///      Transient storage (EIP-1153) would be the natural home for this and would save roughly
    ///      5,000 gas per arbitrage, which is material when competing on margin. It is deliberately
    ///      not used: this contract targets a long tail of EVM chains — the original ships a BSC pair
    ///      list and the sibling bot enumerates Celo, Fantom and Harmony — and `TSTORE` requires
    ///      Cancun. Portability wins over 5,000 gas. Switch to `transient` if you only deploy to
    ///      chains you have verified support it.
    address private permissionedPairAddress = address(1);

    /// @notice WETH on Ethereum, WBNB on BSC, and so on for other chains.
    address public immutable WETH;

    /// @dev Tokens the bot is willing to hold and denominate profit in.
    EnumerableSet.AddressSet private baseTokens;

    /// @notice Fee numerator applied when a pool has no explicit override. 997 == 0.30%.
    uint256 public defaultFeeNumerator = 997;

    /// @notice Per-pool fee numerator over `PairMath.FEE_DENOMINATOR`. Zero means "use the default".
    /// @dev 997 = 0.30% (Uniswap V2, SushiSwap), 998 = 0.20% (ApeSwap, PancakeSwap V1).
    ///      Quoting a pool with the wrong fee silently corrupts every profit estimate for it, so
    ///      overrides should be set before that pool is ever passed to {flashArbitrage}.
    mapping(address pool => uint256 feeNumerator) public pairFeeNumeratorOverride;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Withdrawn(address indexed to, uint256 value);
    event TokenWithdrawn(address indexed token, address indexed to, uint256 value);
    event BaseTokenAdded(address indexed token);
    event BaseTokenRemoved(address indexed token);
    event DefaultFeeNumeratorUpdated(uint256 previous, uint256 current);
    event PairFeeNumeratorUpdated(address indexed pool, uint256 previous, uint256 current);
    event Arbitrage(address indexed lowerPool, address indexed higherPool, address indexed baseToken, uint256 profit);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error SamePairAddress();
    error NonStandardPair();
    error PairTokenMismatch();
    error NoBaseTokenInPair();
    error NoProfit();
    error LosingMoney();
    error UnpermissionedCallback();
    error CallbackSenderMismatch();
    error ComplexRoot();
    error NoValidBorrowAmount();
    error EthTransferFailed();
    error ZeroAddress();
    error InvalidFeeNumerator();
    error ReservesTooLargeToScale();

    constructor(address _WETH) Ownable(msg.sender) {
        if (_WETH == address(0)) revert ZeroAddress();
        WETH = _WETH;
        baseTokens.add(_WETH);
    }

    receive() external payable {}

    /// @dev Different V2 forks name their flash-swap callback differently (`uniswapV2Call`,
    ///      `pancakeCall`, `apeCall`, ...). Rather than implement each one, decode any unrecognised
    ///      selector's arguments and dispatch. The original declared `returns (bytes memory)` and
    ///      never assigned it; nothing consumes the value, so it is dropped explicitly instead.
    fallback(bytes calldata _input) external returns (bytes memory) {
        (address sender, uint256 amount0, uint256 amount1, bytes memory data) =
            abi.decode(_input[4:], (address, uint256, uint256, bytes));
        uniswapV2Call(sender, amount0, amount1, data);
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                              ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Sweeps native currency and every base token to the owner.
    ///
    /// @dev Two changes from the original. It is now `onlyOwner`: the original was callable by anyone,
    ///      and while funds could only ever go to the owner, an unguarded loop over attacker-influenced
    ///      token contracts is free griefing. And a reverting token no longer strands everything else —
    ///      each transfer is attempted independently, so one hostile base token in the set cannot block
    ///      recovery of the rest. {withdrawToken} handles anything left behind.
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            // `.transfer` forwards only 2300 gas and fails outright when the owner is a Safe or any
            // other contract with a non-trivial receive hook.
            (bool ok,) = payable(owner()).call{value: balance}("");
            if (!ok) revert EthTransferFailed();
            emit Withdrawn(owner(), balance);
        }

        uint256 length = baseTokens.length();
        for (uint256 i; i < length; ++i) {
            address token = baseTokens.at(i);
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            if (tokenBalance == 0) continue;
            // Deliberately a raw call: a token that reverts, or returns nothing, must not abort the
            // rest of the sweep. Failures are silent by design and recoverable via withdrawToken.
            (bool ok,) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, owner(), tokenBalance));
            if (ok) emit TokenWithdrawn(token, owner(), tokenBalance);
        }
    }

    /// @notice Recovers an arbitrary token, including one never registered as a base token.
    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(owner(), balance);
            emit TokenWithdrawn(token, owner(), balance);
        }
    }

    function addBaseToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        baseTokens.add(token);
        emit BaseTokenAdded(token);
    }

    function removeBaseToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            (bool ok,) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, owner(), balance));
            if (ok) emit TokenWithdrawn(token, owner(), balance);
        }
        baseTokens.remove(token);
        emit BaseTokenRemoved(token);
    }

    function setDefaultFeeNumerator(uint256 feeNumerator) external onlyOwner {
        if (feeNumerator < PairMath.MIN_FEE_NUMERATOR || feeNumerator > PairMath.FEE_DENOMINATOR) {
            revert InvalidFeeNumerator();
        }
        emit DefaultFeeNumeratorUpdated(defaultFeeNumerator, feeNumerator);
        defaultFeeNumerator = feeNumerator;
    }

    /// @notice Records the actual swap fee of a specific pool. Pass 0 to fall back to the default.
    function setPairFeeNumerator(address pool, uint256 feeNumerator) external onlyOwner {
        if (feeNumerator != 0 && (feeNumerator < PairMath.MIN_FEE_NUMERATOR || feeNumerator > PairMath.FEE_DENOMINATOR))
        {
            revert InvalidFeeNumerator();
        }
        emit PairFeeNumeratorUpdated(pool, pairFeeNumeratorOverride[pool], feeNumerator);
        pairFeeNumeratorOverride[pool] = feeNumerator;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Effective fee numerator for `pool`.
    function feeNumeratorOf(address pool) public view returns (uint256) {
        uint256 override_ = pairFeeNumeratorOverride[pool];
        return override_ == 0 ? defaultFeeNumerator : override_;
    }

    function getBaseTokens() external view returns (address[] memory tokens) {
        return baseTokens.values();
    }

    function baseTokensContains(address token) public view returns (bool) {
        return baseTokens.contains(token);
    }

    /// @notice Profit obtainable by arbitraging between two pools, denominated in the base token.
    /// @dev Returns zero rather than reverting when there is nothing to take, so callers can poll it
    ///      cheaply. Uses each pool's recorded fee.
    function getProfit(address pool0, address pool1) external view returns (uint256 profit, address baseToken) {
        (bool baseTokenSmaller,,) = isBaseTokenSmaller(pool0, pool1);
        baseToken = baseTokenSmaller ? IUniswapV2Pair(pool0).token0() : IUniswapV2Pair(pool0).token1();

        (address lowerPool, address higherPool, OrderedReserves memory reserves) =
            getOrderedReserves(pool0, pool1, baseTokenSmaller);

        uint256 borrowAmount = calcBorrowAmount(reserves);
        uint256 debtAmount = PairMath.getAmountIn(borrowAmount, reserves.a1, reserves.b1, feeNumeratorOf(lowerPool));
        uint256 baseTokenOutAmount =
            PairMath.getAmountOut(borrowAmount, reserves.b2, reserves.a2, feeNumeratorOf(higherPool));

        profit = baseTokenOutAmount > debtAmount ? baseTokenOutAmount - debtAmount : 0;
    }

    /*//////////////////////////////////////////////////////////////
                                ARBITRAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Arbitrages between two pools holding the same token pair.
    function flashArbitrage(address pool0, address pool1) external {
        ArbitrageInfo memory info;
        (info.baseTokenSmaller, info.baseToken, info.quoteToken) = isBaseTokenSmaller(pool0, pool1);

        OrderedReserves memory orderedReserves;
        (info.lowerPool, info.higherPool, orderedReserves) = getOrderedReserves(pool0, pool1, info.baseTokenSmaller);

        // Must be refreshed every transaction so the callback can authenticate its origin.
        permissionedPairAddress = info.lowerPool;

        uint256 balanceBefore = IERC20(info.baseToken).balanceOf(address(this));

        // Scoped to keep the stack shallow enough to compile.
        {
            uint256 borrowAmount = calcBorrowAmount(orderedReserves);
            (uint256 amount0Out, uint256 amount1Out) =
                info.baseTokenSmaller ? (uint256(0), borrowAmount) : (borrowAmount, uint256(0));

            // Borrow quote token from the cheaper pool; this is what we owe it, in base token.
            uint256 debtAmount = PairMath.getAmountIn(
                borrowAmount, orderedReserves.a1, orderedReserves.b1, feeNumeratorOf(info.lowerPool)
            );
            // Sell the borrowed quote token into the richer pool.
            uint256 baseTokenOutAmount = PairMath.getAmountOut(
                borrowAmount, orderedReserves.b2, orderedReserves.a2, feeNumeratorOf(info.higherPool)
            );
            if (baseTokenOutAmount <= debtAmount) revert NoProfit();

            CallbackData memory callbackData;
            callbackData.debtPool = info.lowerPool;
            callbackData.targetPool = info.higherPool;
            callbackData.debtTokenSmaller = info.baseTokenSmaller;
            callbackData.borrowedToken = info.quoteToken;
            callbackData.debtToken = info.baseToken;
            callbackData.debtAmount = debtAmount;
            callbackData.debtTokenOutAmount = baseTokenOutAmount;

            IUniswapV2Pair(info.lowerPool).swap(amount0Out, amount1Out, address(this), abi.encode(callbackData));
        }

        uint256 balanceAfter = IERC20(info.baseToken).balanceOf(address(this));
        if (balanceAfter <= balanceBefore) revert LosingMoney();

        emit Arbitrage(info.lowerPool, info.higherPool, info.baseToken, balanceAfter - balanceBefore);

        if (info.baseToken == WETH) {
            IWETH(info.baseToken).withdraw(balanceAfter);
        }
        permissionedPairAddress = address(1);
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes memory data) public {
        if (msg.sender != permissionedPairAddress) revert UnpermissionedCallback();
        if (sender != address(this)) revert CallbackSenderMismatch();

        uint256 borrowedAmount = amount0 > 0 ? amount0 : amount1;
        CallbackData memory info = abi.decode(data, (CallbackData));

        IERC20(info.borrowedToken).safeTransfer(info.targetPool, borrowedAmount);

        (uint256 amount0Out, uint256 amount1Out) =
            info.debtTokenSmaller ? (info.debtTokenOutAmount, uint256(0)) : (uint256(0), info.debtTokenOutAmount);
        IUniswapV2Pair(info.targetPool).swap(amount0Out, amount1Out, address(this), new bytes(0));

        IERC20(info.debtToken).safeTransfer(info.debtPool, info.debtAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    function isBaseTokenSmaller(address pool0, address pool1)
        internal
        view
        returns (bool baseSmaller, address baseToken, address quoteToken)
    {
        if (pool0 == pool1) revert SamePairAddress();
        (address pool0Token0, address pool0Token1) = (IUniswapV2Pair(pool0).token0(), IUniswapV2Pair(pool0).token1());
        (address pool1Token0, address pool1Token1) = (IUniswapV2Pair(pool1).token0(), IUniswapV2Pair(pool1).token1());
        if (pool0Token0 >= pool0Token1 || pool1Token0 >= pool1Token1) revert NonStandardPair();
        if (pool0Token0 != pool1Token0 || pool0Token1 != pool1Token1) revert PairTokenMismatch();
        if (!baseTokensContains(pool0Token0) && !baseTokensContains(pool0Token1)) revert NoBaseTokenInPair();

        (baseSmaller, baseToken, quoteToken) =
            baseTokensContains(pool0Token0) ? (true, pool0Token0, pool0Token1) : (false, pool0Token1, pool0Token0);
    }

    /// @dev Orders the two pools by price denominated in the quote asset, cheaper pool first.
    function getOrderedReserves(address pool0, address pool1, bool baseTokenSmaller)
        internal
        view
        returns (address lowerPool, address higherPool, OrderedReserves memory orderedReserves)
    {
        (uint256 pool0Reserve0, uint256 pool0Reserve1,) = IUniswapV2Pair(pool0).getReserves();
        (uint256 pool1Reserve0, uint256 pool1Reserve1,) = IUniswapV2Pair(pool1).getReserves();

        // (base, quote) reserves for each pool.
        (uint256 a0, uint256 b0) = baseTokenSmaller ? (pool0Reserve0, pool0Reserve1) : (pool0Reserve1, pool0Reserve0);
        (uint256 a1, uint256 b1) = baseTokenSmaller ? (pool1Reserve0, pool1Reserve1) : (pool1Reserve1, pool1Reserve0);

        // Exact comparison; see PairMath.firstPriceIsLower for why this replaced Decimal.div.
        if (PairMath.firstPriceIsLower(a0, b0, a1, b1)) {
            (lowerPool, higherPool) = (pool0, pool1);
            (orderedReserves.a1, orderedReserves.b1, orderedReserves.a2, orderedReserves.b2) = (a0, b0, a1, b1);
        } else {
            (lowerPool, higherPool) = (pool1, pool0);
            (orderedReserves.a1, orderedReserves.b1, orderedReserves.a2, orderedReserves.b2) = (a1, b1, a0, b0);
        }
    }

    /// @dev Borrow size that maximises profit, found by solving the first-order condition.
    ///
    ///      The intermediate terms are quartic in the reserves and overflow `int256` at realistic
    ///      magnitudes, so the reserves are scaled down by a power of two first and the result scaled
    ///      back up. The original chose that divisor from a hardcoded ladder of decimal thresholds and
    ///      noted it was "only suitable for ERC20 token with 18 decimals" — which silently mis-scaled
    ///      USDC, WBTC and every other token that is not 18 decimals, and mis-scaled all of them once
    ///      reserves left the anticipated range.
    ///
    ///      This version derives the shift from the actual bit width. `c` is a product of four scaled
    ///      terms and `b^2` of six, so every scaled term must stay below `2^42` to keep `b^2 - 4ac`
    ///      inside `int256`. Shifting by `bitlen(max) - 42` guarantees that for any decimals and any
    ///      reserve size, and is the smallest such shift, so it also discards less precision than the
    ///      ladder did in most cases.
    function calcBorrowAmount(OrderedReserves memory reserves) internal pure returns (uint256 amount) {
        uint256 maxReserve = reserves.a1;
        if (reserves.b1 > maxReserve) maxReserve = reserves.b1;
        if (reserves.a2 > maxReserve) maxReserve = reserves.a2;
        if (reserves.b2 > maxReserve) maxReserve = reserves.b2;
        if (maxReserve == 0) revert NoValidBorrowAmount();

        uint256 shift;
        uint256 width = PairMath.log2Floor(maxReserve) + 1;
        if (width > 42) shift = width - 42;
        // Uniswap V2 reserves are uint112, so width <= 112 and shift <= 70. Belt and braces.
        if (shift > 200) revert ReservesTooLargeToScale();

        int256 a1 = int256(reserves.a1 >> shift);
        int256 b1 = int256(reserves.b1 >> shift);
        int256 a2 = int256(reserves.a2 >> shift);
        int256 b2 = int256(reserves.b2 >> shift);

        int256 a = a1 * b1 - a2 * b2;
        int256 b = 2 * b1 * b2 * (a1 + a2);
        int256 c = b1 * b2 * (a1 * b2 - a2 * b1);

        (int256 x1, int256 x2) = calcSolutionForQuadratic(a, b, c);

        // The borrow must be positive and leave both pools solvent.
        bool firstValid = x1 > 0 && x1 < b1 && x1 < b2;
        bool secondValid = x2 > 0 && x2 < b1 && x2 < b2;
        if (!firstValid && !secondValid) revert NoValidBorrowAmount();

        amount = uint256(firstValid ? x1 : x2) << shift;
    }

    /// @dev Positive roots of `ax^2 + bx + c = 0`.
    ///      The original required `m > 0`, rejecting the legitimate double root at `m == 0`.
    function calcSolutionForQuadratic(int256 a, int256 b, int256 c) internal pure returns (int256 x1, int256 x2) {
        int256 m = b * b - 4 * a * c;
        if (m < 0) revert ComplexRoot();

        int256 sqrtM = int256(PairMath.sqrt(uint256(m)));
        x1 = (-b + sqrtM) / (2 * a);
        x2 = (-b - sqrtM) / (2 * a);
    }
}
