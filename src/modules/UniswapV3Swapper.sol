// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ISwapRouter} from "@uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";

/// @title UniswapV3Swapper - A generalized Uniswap V3 integration to perform limit order swaps in any Uniswap V3 implementation.
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract UniswapV3Swapper is IExternalSwapModule {
  /// @dev Storage slot for factory to router mapping
  /// Computed as keccak256("UniswapV3Swapper::FactoryRouters")
  bytes32 private constant ROUTERS_POSITION = 0xa2f306976a35d0b6463fdbc96489b3560c2c3d750c9f0df8e8a72070efd982e4;

  error RouterAlreadySet();
  error Unauthorized();

  /// @dev Returns the routers mapping storage
  /// @return routers The mapping from factory addresses to router addresses
  function getRoutersMapping() internal pure returns (mapping(address => address) storage routers) {
    assembly {
      routers.slot := ROUTERS_POSITION
    }
  }

  /// @notice Sets the router for a specific factory
  /// @dev Only callable by the owner of the main contract
  /// @param factory Address of the Uniswap V3 factory
  /// @param router Address of the router to use for this factory
  function setRouterForFactory(address factory, address router) external {
    // TODO: Implement proper admin check considering delegatecall context
    mapping(address => address) storage routers = getRoutersMapping();
    if (routers[factory] != address(0)) revert RouterAlreadySet();
    routers[factory] = router;
  }

  /// @notice Retrieves the swap router associated with a specific pool
  /// @param pool Address of the Uniswap V3 pool
  /// @return router The ISwapRouter interface of the associated router
  function getRouterForUniswapV3Pool(address pool) public view returns (ISwapRouter router) {
    address factory = IUniswapV3Pool(pool).factory();
    router = ISwapRouter(getRoutersMapping()[factory]);
  }

  /// @inheritdoc IExternalSwapModule
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, address pool, bytes memory data) public {
    // Ignore compiler warnings
    data;

    int24 mgvTick = int24(Tick.unwrap(maxTick));
    int24 uniswapTick = _convertToUniswapTick(olKey.inbound_tkn, pool, mgvTick);

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
