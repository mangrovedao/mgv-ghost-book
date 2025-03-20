// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IAerodromeRouter} from "src/interface/vendors/IAerodrome.sol";
import "@openzeppelin-contracts/utils/math/Math.sol";

/// @title AerodromeSwapper - An Aerodrome integration to perform limit order swaps on Aerodrome pools
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract AerodromeSwapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error RouterNotSet();
  error Unauthorized();
  error PriceExceedsLimit();

  address public immutable ghostBook;
  address public immutable router;

  uint256 public constant FEE_PRECISION = 10_000;

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

    address inToken = olKey.inbound_tkn;
    address outToken = olKey.outbound_tkn;

    // Prepare route for Aerodrome swap
    IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
    routes[0] = IAerodromeRouter.Route({from: inToken, to: outToken, stable: stable, factory: factory});

    // First, check if we can swap the full amount within price limit
    uint256 swapAmount = amountToSell;

    try IAerodromeRouter(router).getAmountsOut(swapAmount, routes) returns (uint256[] memory amounts) {
      uint256 expectedOutput = amounts[amounts.length - 1];
      Tick estimatedTick = TickLib.tickFromVolumes(swapAmount, expectedOutput);

      // If estimated price is worse than maxTick, calculate the maximum amount we can swap
      if (Tick.unwrap(estimatedTick) > Tick.unwrap(maxTick)) {
        // Binary search to find the largest amount that stays within price limit
        swapAmount = _findMaxSwapAmount(inToken, routes, maxTick, swapAmount);

        // If we couldn't find a valid amount, return without swapping
        if (swapAmount == 0) {
          return;
        }
      }
    } catch {
      // If getAmountsOut fails, we'll try with a smaller amount
      swapAmount = amountToSell / 2;
    }

    uint256 initialInbound = IERC20(inToken).balanceOf(address(this));
    uint256 initialOutbound = IERC20(outToken).balanceOf(address(this));

    // Approve router to spend tokens
    IERC20(inToken).approve(address(router), swapAmount);

    try IAerodromeRouter(router).swapExactTokensForTokens(swapAmount, 0, routes, address(this), deadline) {
      // Calculate actual amounts from balance differences
      uint256 gave = initialInbound - IERC20(inToken).balanceOf(address(this));
      uint256 got = IERC20(outToken).balanceOf(address(this)) - initialOutbound;

      // Verify price is within limits
      if (gave > 0 && got > 0) {
        Tick inferredTick = TickLib.tickFromVolumes(gave, got);
        if (Tick.unwrap(inferredTick) > Tick.unwrap(maxTick)) {
          revert PriceExceedsLimit();
        }
      }

      // Reset approval and transfer tokens back
      _returnTokens(inToken, outToken, got, msg.sender);
    } catch {
      // If swap fails, return tokens to caller
      _returnTokens(inToken, outToken, 0, msg.sender);
    }
  }

  /// @dev Find the maximum amount that can be swapped within the price limit
  /// @param inToken The input token
  /// @param routes The swap routes
  /// @param maxTick The maximum acceptable price tick
  /// @param initialAmount The initial amount to try
  /// @return maxAmount The maximum amount that can be swapped within price limit
  function _findMaxSwapAmount(
    address inToken,
    IAerodromeRouter.Route[] memory routes,
    Tick maxTick,
    uint256 initialAmount
  ) internal view returns (uint256 maxAmount) {
    uint256 low = 0;
    uint256 high = initialAmount;
    uint256 mid;
    uint256 bestAmount = 0;

    // Binary search with a maximum of 8 iterations
    for (uint256 i = 0; i < 8; i++) {
      if (low >= high) break;

      mid = (low + high) / 2;
      if (mid == 0) break;

      try IAerodromeRouter(router).getAmountsOut(mid, routes) returns (uint256[] memory amounts) {
        uint256 expectedOutput = amounts[amounts.length - 1];
        Tick estimatedTick = TickLib.tickFromVolumes(mid, expectedOutput);

        if (Tick.unwrap(estimatedTick) <= Tick.unwrap(maxTick)) {
          // This amount works, try a larger one
          bestAmount = mid;
          low = mid + 1;
        } else {
          // This amount exceeds price limit, try a smaller one
          high = mid;
        }
      } catch {
        // Query failed, try a smaller amount
        high = mid;
      }
    }

    return bestAmount;
  }

  /// @dev Return tokens back to the caller
  function _returnTokens(address inToken, address outToken, uint256 gotAmount, address recipient) internal {
    IERC20(inToken).approve(address(router), 0);

    uint256 remainingInToken = IERC20(inToken).balanceOf(address(this));
    if (remainingInToken > 0) {
      IERC20(inToken).safeTransfer(recipient, remainingInToken);
    }

    if (gotAmount > 0) {
      IERC20(outToken).safeTransfer(recipient, gotAmount);
    }
  }
}
