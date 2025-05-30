// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ISwapOperations} from "../interface/vendors/ISwapOperations.sol";

/// @title BalancerV1Swapper - A SwapOperations integration for limit order swaps
/// @notice This contract serves as a plugin for the GhostBook contract
contract BalancerV1Swapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error Unauthorized();
  error RouterNotSet();
  error DeadlineExceeded();
  error PriceExceedsLimit();

  address public immutable ghostBook;

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
    // Decode router and deadline from data
    (address swapRouter, uint256 deadline) = abi.decode(data, (address, uint256));

    if (swapRouter == address(0)) {
      revert RouterNotSet();
    }

    // Prepare path for swap
    address[] memory path = new address[](2);
    path[0] = olKey.inbound_tkn;
    path[1] = olKey.outbound_tkn;

    // First, check if we can swap the full amount within price limit
    uint256 swapAmount = amountToSell;
    try ISwapOperations(swapRouter).getAmountsOut(swapAmount, path) returns (
      ISwapOperations.SwapAmount[] memory amounts, bool isUsablePrice
    ) {
      if (isUsablePrice && amounts.length > 0) {
        uint256 expectedOutput = amounts[amounts.length - 1].amount;
        Tick estimatedTick = TickLib.tickFromVolumes(swapAmount, expectedOutput);

        // If estimated price is worse than maxTick, calculate the maximum amount we can swap
        if (Tick.unwrap(estimatedTick) > Tick.unwrap(maxTick)) {
          // Binary search to find the largest amount that stays within price limit
          swapAmount = _findMaxSwapAmount(swapRouter, path, maxTick, swapAmount);

          // If we couldn't find a valid amount, return without swapping
          if (swapAmount == 0) {
            return;
          }
        }
      }
    } catch {
      // If getAmountsOut fails, we'll try with a smaller amount
      swapAmount = amountToSell / 2;
    }

    // Record initial balances
    uint256 initialInbound = IERC20(olKey.inbound_tkn).balanceOf(address(this));
    uint256 initialOutbound = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Approve router to spend tokens
    IERC20(olKey.inbound_tkn).forceApprove(swapRouter, swapAmount);

    // Execute swap - using empty array for price update data
    bytes[] memory emptyPriceUpdateData = new bytes[](0);
    try ISwapOperations(swapRouter).swapExactTokensForTokens(
      swapAmount, 0, path, address(this), deadline, emptyPriceUpdateData
    ) {
      // Calculate actual amounts from balance differences
      uint256 gave = initialInbound - IERC20(olKey.inbound_tkn).balanceOf(address(this));
      uint256 got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - initialOutbound;

      // Verify price is within limits
      if (gave > 0 && got > 0) {
        Tick inferredTick = TickLib.tickFromVolumes(gave, got);
        if (Tick.unwrap(inferredTick) > Tick.unwrap(maxTick)) {
          revert PriceExceedsLimit();
        }
      }

      // Reset approval and transfer tokens back
      _returnTokens(swapRouter, olKey.inbound_tkn, olKey.outbound_tkn, got);
    } catch {
      // If swap fails, return tokens to caller
      _returnTokens(swapRouter, olKey.inbound_tkn, olKey.outbound_tkn, 0);
    }
  }

  /// @dev Find the maximum amount that can be swapped within the price limit
  /// @param router The router to use for the swap
  /// @param path The swap path
  /// @param maxTick The maximum acceptable price tick
  /// @param initialAmount The initial amount to try
  /// @return maxAmount The maximum amount that can be swapped within price limit
  function _findMaxSwapAmount(address router, address[] memory path, Tick maxTick, uint256 initialAmount)
    internal
    view
    returns (uint256 maxAmount)
  {
    uint256 low = 0;
    uint256 high = initialAmount;
    uint256 mid;
    uint256 bestAmount = 0;

    // Binary search with a maximum of 8 iterations
    for (uint256 i = 0; i < 8; i++) {
      if (low >= high) break;
      mid = (low + high) / 2;
      if (mid == 0) break;

      try ISwapOperations(router).getAmountsOut(mid, path) returns (
        ISwapOperations.SwapAmount[] memory amounts, bool isUsablePrice
      ) {
        if (isUsablePrice && amounts.length > 0) {
          uint256 expectedOutput = amounts[amounts.length - 1].amount;
          Tick estimatedTick = TickLib.tickFromVolumes(mid, expectedOutput);

          if (Tick.unwrap(estimatedTick) <= Tick.unwrap(maxTick)) {
            // This amount works, try a larger one
            bestAmount = mid;
            low = mid + 1;
          } else {
            // This amount exceeds price limit, try a smaller one
            high = mid;
          }
        } else {
          // Unusable price, try a smaller amount
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
  function _returnTokens(address router, address inToken, address outToken, uint256 gotAmount) internal {
    IERC20(inToken).forceApprove(router, 0);

    uint256 remainingInToken = IERC20(inToken).balanceOf(address(this));
    if (remainingInToken > 0) {
      IERC20(inToken).safeTransfer(ghostBook, remainingInToken);
    }

    if (gotAmount > 0) {
      IERC20(outToken).safeTransfer(ghostBook, gotAmount);
    }
  }
}
