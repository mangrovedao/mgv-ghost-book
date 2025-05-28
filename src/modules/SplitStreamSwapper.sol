// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniswapV3Swapper, OLKey, Tick, IERC20, TickMath, SafeERC20} from "./UniswapV3Swapper.sol";
import {ISplitStreamRouter} from "src/interface/vendors/ISplitStreamRouter.sol";

contract SplitStreamSwapper is UniswapV3Swapper {
  using SafeERC20 for IERC20;

  constructor(address _ghostBook) UniswapV3Swapper(_ghostBook) {}

  /// @inheritdoc UniswapV3Swapper
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data)
    external
    override
    onlyGhostBook
  {
    // Decode needed data for the swap
    (address router, uint24 fee, uint256 deadline, uint24 tickSpacing) = _decodeSwapData(data);

    // Approve router to spend tokens
    IERC20(olKey.inbound_tkn).forceApprove(address(router), amountToSell);

    // Calculate price limit
    uint160 sqrtPriceLimitX96 = _calculatePriceLimit(olKey, maxTick, fee);

    // Prepare for the swap and store initial balances
    (uint256 initialInboundBalance, uint256 initialOutboundBalance) = _prepareForSwap(olKey, amountToSell);

    // Execute the swap
    _executeSwap(router, olKey, amountToSell, deadline, tickSpacing, sqrtPriceLimitX96);

    // Finalize the swap and transfer tokens back
    _finalizeSwap(router, olKey, initialInboundBalance, initialOutboundBalance);
  }

  /**
   * @dev Decodes the swap data from bytes
   * @param data The encoded swap data
   * @return router The router address
   * @return fee The fee amount
   * @return deadline The swap deadline
   * @return tickSpacing The tick spacing
   */
  function _decodeSwapData(bytes memory data)
    internal
    pure
    returns (address router, uint24 fee, uint256 deadline, uint24 tickSpacing)
  {
    return abi.decode(data, (address, uint24, uint256, uint24));
  }

  /**
   * @dev Calculates the price limit for the swap
   * @param olKey The order book key
   * @param maxTick The maximum tick
   * @param fee The fee amount
   * @return sqrtPriceLimitX96 The calculated price limit
   */
  function _calculatePriceLimit(OLKey memory olKey, Tick maxTick, uint24 fee)
    internal
    view
    returns (uint160 sqrtPriceLimitX96)
  {
    int24 uniswapTick = _adjustTickForUniswap(olKey.inbound_tkn, olKey.outbound_tkn, maxTick, fee);

    // Validate price limit is within bounds
    return TickMath.getSqrtRatioAtTick(uniswapTick);
  }

  /**
   * @dev Prepares for the swap by storing initial balances
   * @param olKey The order book key
   * @param amountToSell The amount to sell
   * @return initialInboundBalance The initial balance of inbound token
   * @return initialOutboundBalance The initial balance of outbound token
   */
  function _prepareForSwap(OLKey memory olKey, uint256 amountToSell)
    internal
    view
    returns (uint256 initialInboundBalance, uint256 initialOutboundBalance)
  {
    initialInboundBalance = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - amountToSell;
    initialOutboundBalance = IERC20(olKey.outbound_tkn).balanceOf(address(this));
    return (initialInboundBalance, initialOutboundBalance);
  }

  /**
   * @dev Executes the swap through the SplitStream router
   * @param router The router address
   * @param olKey The order book key
   * @param amountToSell The amount to sell
   * @param deadline The swap deadline
   * @param tickSpacing The tick spacing
   * @param sqrtPriceLimitX96 The price limit
   */
  function _executeSwap(
    address router,
    OLKey memory olKey,
    uint256 amountToSell,
    uint256 deadline,
    uint24 tickSpacing,
    uint160 sqrtPriceLimitX96
  ) internal {
    ISplitStreamRouter.ExactInputSingleParams memory params = ISplitStreamRouter.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      tickSpacing: int24(tickSpacing),
      recipient: address(this),
      deadline: deadline,
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISplitStreamRouter(router).exactInputSingle(params);
  }

  /**
   * @dev Finalizes the swap by calculating amounts and transferring tokens
   * @param router The router address
   * @param olKey The order book key
   * @param initialInboundBalance The initial balance of inbound token
   * @param initialOutboundBalance The initial balance of outbound token
   */
  function _finalizeSwap(
    address router,
    OLKey memory olKey,
    uint256 initialInboundBalance,
    uint256 initialOutboundBalance
  ) internal {
    // Calculate actual amounts from balance differences
    uint256 gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - initialInboundBalance;
    uint256 got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - initialOutboundBalance;

    // Transfer tokens back
    IERC20(olKey.inbound_tkn).forceApprove(address(router), 0);
    IERC20(olKey.inbound_tkn).safeTransfer(msg.sender, gave);
    IERC20(olKey.outbound_tkn).safeTransfer(msg.sender, got);
  }
}
