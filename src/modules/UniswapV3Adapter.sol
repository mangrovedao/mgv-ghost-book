// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMangrove} from "@mgv/src/IMangrove.sol";
import {ISwapRouter} from "@uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

/* UniswapV3Adapter enables swapping tokens through Uniswap V3 pools with a limit price. */
contract UniswapV3Adapter {
  using SafeTransferLib for address;

  /* # State variables */

  /* The core Mangrove contract. */
  IMangrove public mgv;
  /* Uniswap V3 universal router. */
  ISwapRouter public swapRouter;

  /* Pool contains token addresses and fee tier for a Uniswap V3 pool. */
  struct Pool {
    /* First token of the pair */
    address tokenA;
    /* Second token of the pair */
    address tokenB;
    /* Pool fee tier in basis points */
    uint24 fee;
  }

  constructor(address payable _mgv, address _swapRouter) {
    mgv = IMangrove(_mgv);
    swapRouter = ISwapRouter(_swapRouter);
  }

  /* Swaps tokens through Uniswap V3 with a limit price. Stops when either limit price is reached or maxAmountIn is consumed.
     @param isTokenZeroIn Whether tokenA is being sold (true) or bought (false)
     @param maxAmountIn Maximum amount of input tokens to swap
     @param maxTick Maximum tick (price) for the swap
     @param pool Pool parameters for the swap
     @return amountIn Actual amount of input tokens consumed
     @return amountOut Amount of output tokens received
  */
  function swapLimitPrice(bool isTokenZeroIn, uint256 maxAmountIn, int24 maxTick, Pool calldata pool)
    external
    returns (uint256 amountIn, uint256 amountOut)
  {
    (address tokenIn, address tokenOut) = isTokenZeroIn ? (pool.tokenA, pool.tokenB) : (pool.tokenB, pool.tokenA);
    // Transfer tokens to contract
    tokenIn.safeTransferFrom(msg.sender, address(this), maxAmountIn);

    // Approve Router
    tokenIn.safeApprove(address(swapRouter), maxAmountIn);

    // Perform swap with price limit
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      fee: pool.fee,
      recipient: msg.sender,
      deadline: block.timestamp,
      amountIn: maxAmountIn,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(maxTick)
    });
    
    amountOut = swapRouter.exactInputSingle(params);
    uint256 nonConsumed = tokenIn.balanceOf(address(this));
    amountIn = maxAmountIn - nonConsumed;
    tokenIn.safeTransfer(msg.sender, nonConsumed);
  }
}