// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {ISwapRouter} from "@uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

/// @title UniswapV3Swapper - A generalized Uniswap V3 integration to perform limit order swaps in any Uniswap V3 implementation.
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract UniswapV3Swapper is IExternalSwapModule {
  /// @dev The storage slot for the UniswapV3 router.
  // keccak256("UniswapV3Swapper::SwapRouter")
  uint256 private constant _ROUTER_SLOT_SEED = 0x17ca64c2c7f79fe0bd30eb4a97259e88899f200c96a8d51eaa8df688f5643fb1;

  /// @notice Special function to initialize the storage, can obly be called once
  function setRouterForUniswapV3Pool(address _pool, address _swapRouter) public {
    if (_swapRouter != address(0)) revert();
    assembly {
      // Compute the router slot
      mstore(0x0c, _ROUTER_SLOT_SEED)
      mstore(0x00, _pool)
      let routerSlot := keccak256(0x0c, 0x20)
      // Store the new value
      sstore(routerSlot, _swapRouter)
    }
  }

  /// @notice Retrieves the swap router associated with a specific pool
  /// @param pool Address of the Uniswap V3 pool
  /// @return router The ISwapRouter interface of the associated router
  function getRouterForUniswapV3Pool(address pool) public view returns (ISwapRouter router) {
    assembly {
      mstore(0x0c, _ROUTER_SLOT_SEED)
      mstore(0x00, pool)
      router := sload(keccak256(0x0c, 0x20))
    }
  }

  /// @dev Helper function to convert from Mangrove tick to Uniswap tick as prices are represented differently
  function _convertToUniswapTick(address inboundToken, IUniswapV3Pool pool, int24 mgvTick)
    internal
    view
    returns (int24)
  {
    // In Uniswap price is token1/token0
    // If inbound is token0, we need to negate the tick
    // since Mangrove price is inbound/outbound
    address token0 = pool.token0();
    return inboundToken == token0 ? -mgvTick : mgvTick;
  }

  /// @inheritdoc IExternalSwapModule
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, address pool, bytes memory data) public {
    // Ignore compiler warnings
    data;
    if (msg.sender != address(this)) revert GhostBookErrors.OnlyThisContractCanCallThisFunction();

    int24 mgvTick = int24(Tick.unwrap(maxTick));
    int24 uniswapTick = _convertToUniswapTick(olKey.inbound_tkn, IUniswapV3Pool(pool), mgvTick);

    // Perform swap with price limit
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      fee: IUniswapV3Pool(pool).fee(),
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(uniswapTick)
    });

    getRouterForUniswapV3Pool(pool).exactInputSingle(params);
  }

  /// @inheritdoc IExternalSwapModule
  function spenderFor(address pool) public view returns (address) {
    return address(getRouterForUniswapV3Pool(pool));
  }
}
