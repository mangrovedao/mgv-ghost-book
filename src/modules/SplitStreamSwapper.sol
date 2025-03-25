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
    (address router, uint24 fee, uint256 deadline) = abi.decode(data, (address, uint24, uint256));

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
    ISplitStreamRouter.ExactInputSingleParams memory params = ISplitStreamRouter.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      tickSpacing: int24(int256(olKey.tickSpacing)),
      recipient: address(this),
      deadline: deadline,
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISplitStreamRouter(router).exactInputSingle(params);
    // Calculate actual amounts from balance differences
    gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - gave;
    got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - got;

    // Transfer tokens back
    IERC20(olKey.inbound_tkn).forceApprove(address(router), 0);
    IERC20(olKey.inbound_tkn).safeTransfer(msg.sender, gave);
    IERC20(olKey.outbound_tkn).safeTransfer(msg.sender, got);
  }
}
