// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-contracts/utils/math/Math.sol";
import {IAerodromeRouter} from "src/interface/vendors/IAerodromeRouter.sol";

/// @title AerodromeSwapper - An Aerodrome integration to perform limit order swaps on Aerodrome pools
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract AerodromeSwapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error RouterNotSet();
  error Unauthorized();
  error PriceExceedsLimit();

  address public immutable ghostBook;
  address public immutable router;

  constructor(address _ghostBook, address _router) {
    ghostBook = _ghostBook;
    router = _router;
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
    (bool stable, address factory, uint256 deadline) = abi.decode(data, (bool, address, uint256));

    if (router == address(0)) {
      revert RouterNotSet();
    }

    // Calculate minimum output based on maxTick
    uint256 amountOutMin = _calculateMinimumAmountOut(olKey, amountToSell, maxTick);

    // Store initial balances to track actual swap amounts
    address inToken = olKey.inbound_tkn;
    address outToken = olKey.outbound_tkn;
    uint256 initialInbound = IERC20(inToken).balanceOf(address(this));
    uint256 initialOutbound = IERC20(outToken).balanceOf(address(this));

    // Approve router to spend tokens
    IERC20(inToken).forceApprove(address(router), amountToSell);

    // Prepare route for Aerodrome swap
    IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
    routes[0] = IAerodromeRouter.Route({from: inToken, to: outToken, stable: stable, factory: factory});

    // Perform swap with price limit
    IAerodromeRouter(router).swapExactTokensForTokens(amountToSell, amountOutMin, routes, address(this), deadline);

    // Calculate actual amounts from balance differences
    uint256 gave = initialInbound - IERC20(inToken).balanceOf(address(this));
    uint256 got = IERC20(outToken).balanceOf(address(this)) - initialOutbound;

    // Verify price is within limits
    _validateSwapPrice(gave, got, maxTick);

    // Reset approval and transfer tokens back
    _returnTokens(inToken, outToken, got, msg.sender);
  }

  /// @dev Verify the executed price doesn't exceed maxTick
  function _validateSwapPrice(uint256 gave, uint256 got, Tick maxTick) internal pure {
    // If nothing was swapped, no need to check price
    if (gave == 0 || got == 0) return;

    Tick inferredTick = TickLib.tickFromVolumes(gave, got);
    if (Tick.unwrap(inferredTick) > Tick.unwrap(maxTick)) {
      revert PriceExceedsLimit();
    }
  }

  /// @dev Return tokens back to the caller
  function _returnTokens(address inToken, address outToken, uint256 gotAmount, address recipient) internal {
    IERC20(inToken).forceApprove(address(router), 0);
    IERC20(inToken).safeTransfer(recipient, IERC20(inToken).balanceOf(address(this)));
    IERC20(outToken).safeTransfer(recipient, gotAmount);
  }

  /// @dev Calculate the minimum output amount based on the max tick price
  /// @param olKey The offer list key containing the token pair
  /// @param amountIn Amount of tokens to sell
  /// @param maxTick Maximum price (as a tick) willing to accept
  /// @return minAmountOut Minimum amount to receive to satisfy the max tick price
  function _calculateMinimumAmountOut(OLKey memory olKey, uint256 amountIn, Tick maxTick)
    internal
    pure
    returns (uint256 minAmountOut)
  {
    // In Mangrove, tick represents the price ratio as inbound/outbound
    // We need to convert this to a minimum amount of outbound tokens

    // Use TickLib's outboundFromInbound function
    // This converts an inbound amount to outbound amount based on the tick
    minAmountOut = TickLib.outboundFromInbound(maxTick, amountIn);

    return minAmountOut;
  }

  /// @dev Utility function to get the Aerodrome router route data
  /// @param stable Whether the route uses stable pools
  /// @param factory The factory that created the pool
  /// @param deadline Timestamp after which the swap will revert
  /// @return Encoded bytes to be passed to externalSwap
  function encodeRouteData(bool stable, address factory, uint256 deadline) external pure returns (bytes memory) {
    return abi.encode(stable, factory, deadline);
  }
}
