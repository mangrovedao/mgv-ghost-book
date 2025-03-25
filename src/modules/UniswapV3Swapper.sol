// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ISwapRouterV2} from "../interface/vendors/ISwapRouterV2.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-contracts/utils/math/Math.sol";

/// @title UniswapV3Swapper - A generalized Uniswap V3 integration to perform limit order swaps in any Uniswap V3 implementation.
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract UniswapV3Swapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error RouterAlreadySet();
  error Unauthorized();

  address public immutable ghostBook;
  int256 constant FEE_PRECISION = 1e6;

  constructor(address _ghostBook) {
    ghostBook = _ghostBook;
  }

  modifier onlyGhostBook() {
    if (msg.sender != ghostBook) {
      revert Unauthorized();
    }
    _;
  }

  /// @inheritdoc IExternalSwapModule
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data)
    external
    virtual
    onlyGhostBook
  {
    // Decode needed data for the swap
    (address router, uint24 fee) = abi.decode(data, (address, uint24));

    IERC20(olKey.inbound_tkn).forceApprove(address(router), amountToSell);

    int24 mgvTick = int24(Tick.unwrap(maxTick));
    int24 uniswapTick = _convertToUniswapTick(olKey.inbound_tkn, olKey.outbound_tkn, mgvTick);
    uniswapTick = _adjustTickForFees(uniswapTick, fee);

    // Validate price limit is within bounds
    uint160 sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(uniswapTick);

    // Store initial balances to compare after swap
    uint256 gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - amountToSell;

    uint256 got = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Perform swap with price limit
    ISwapRouterV2.ExactInputSingleParams memory params = ISwapRouterV2.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      fee: fee,
      recipient: address(this),
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISwapRouterV2(router).exactInputSingle(params);
    // Calculate actual amounts from balance differences
    gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - gave;
    got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - got;

    // Transfer tokens back
    IERC20(olKey.inbound_tkn).forceApprove(address(router), 0);
    IERC20(olKey.inbound_tkn).safeTransfer(msg.sender, gave);
    IERC20(olKey.outbound_tkn).safeTransfer(msg.sender, got);
  }

  /// @dev Helper function to convert from Mangrove tick to Uniswap tick as prices are represented differently
  function _convertToUniswapTick(address inboundToken, address outboundToken, int24 mgvTick)
    internal
    pure
    returns (int24)
  {
    // Compare addresses to determine token ordering without storage reads
    // If inbound token has lower address, it's token0 in Uniswap
    return inboundToken < outboundToken ? -mgvTick : mgvTick;
  }

  function _adjustTickForFees(int24 tick, uint24 fee) internal pure returns (int24) {
    // For fee of 500 (0.05%), multiplier is 0.995
    // We want a lower tick that after fees matches our target
    int256 multiplier = int256(uint256(FEE_PRECISION) - uint256(fee));
    // Multiply tick by (1 - fee) to get a lower tick
    return int24((int256(tick) * multiplier) / FEE_PRECISION);
  }
}
