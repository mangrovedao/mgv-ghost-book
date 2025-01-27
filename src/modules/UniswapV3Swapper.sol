// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ISwapRouter} from "@uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "forge-std/src/Test.sol";

/// @title UniswapV3Swapper - A generalized Uniswap V3 integration to perform limit order swaps in any Uniswap V3 implementation.
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract UniswapV3Swapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error RouterAlreadySet();
  error Unauthorized();

  address public ghostBook;

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
    onlyGhostBook
  {
    // Decode needed data for the swap
    (address router, uint24 fee) = abi.decode(data, (address, uint24));

    IERC20(olKey.inbound_tkn).forceApprove(address(router), amountToSell);

    int24 mgvTick = int24(Tick.unwrap(maxTick));
    console.log("mgvTick : ", mgvTick);
    int24 uniswapTick = _convertToUniswapTick(olKey.inbound_tkn, olKey.outbound_tkn, mgvTick);
    console.log("uni Tick : ", uniswapTick);

    // Validate price limit is within bounds
    uint160 sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(uniswapTick);

    // Store initial balances to compare after swap
    uint256 gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - amountToSell;

    uint256 got = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Perform swap with price limit
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      fee: fee,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISwapRouter(router).exactInputSingle(params);
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
}
