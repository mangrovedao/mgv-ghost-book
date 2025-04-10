// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SlippageAwareMockExternalSwapModule
/// @notice A mock module that simulates slippage as trade size increases
/// @dev The larger the trade, the worse the price gets. Will only use the amount that fits under maxTick
contract SlippageAwareMockExternalSwapModule is IExternalSwapModule {
  using SafeERC20 for IERC20;

  IERC20 public immutable inboundToken;
  IERC20 public immutable outboundToken;
  uint256 public immutable baseExchangeRate; // 1 inbound = baseExchangeRate outbound (scaled by 1e18)
  uint256 public immutable slippageFactor; // Higher = more slippage (scaled by 1e18)

  /// @notice Emitted when an external swap is executed
  /// @param sender The address that triggered the swap (typically GhostBook)
  /// @param amountIn Amount of inbound tokens used for the swap
  /// @param amountOut Amount of outbound tokens sent back
  /// @param effectiveRate The effective exchange rate applied (after slippage)
  /// @param inferredTick The tick price inferred from the swap amounts
  /// @param unusedAmount Amount of inbound tokens returned unused
  event SwapExecuted(
    address indexed sender,
    uint256 amountIn,
    uint256 amountOut,
    uint256 effectiveRate,
    int256 inferredTick,
    uint256 unusedAmount
  );

  /// @notice Emitted when a swap is skipped due to price limits
  /// @param sender The address that triggered the swap
  /// @param amountRequested Total amount requested to swap
  /// @param maxTickValue Maximum tick price allowed
  /// @param returnedUnused Amount returned unused
  event SwapSkipped(address indexed sender, uint256 amountRequested, int256 maxTickValue, uint256 returnedUnused);

  /// @notice Emitted when calculating optimal swap amount
  /// @param totalAmount Total amount available to swap
  /// @param optimalAmount Optimal amount that fits within price limits
  /// @param effectiveRate Rate applied at optimal amount
  /// @param inferredTick Inferred tick at optimal amount
  /// @param maxTickValue Maximum tick allowed
  event OptimalAmountCalculated(
    uint256 totalAmount, uint256 optimalAmount, uint256 effectiveRate, int256 inferredTick, int256 maxTickValue
  );

  /// @notice Creates a new slippage-aware mock module
  /// @param _inbound Inbound token address
  /// @param _outbound Outbound token address
  /// @param _baseExchangeRate Base exchange rate (scaled by 1e18)
  /// @param _slippageFactor Slippage factor, higher = more slippage (scaled by 1e18)
  constructor(address _inbound, address _outbound, uint256 _baseExchangeRate, uint256 _slippageFactor) {
    inboundToken = IERC20(_inbound);
    outboundToken = IERC20(_outbound);
    baseExchangeRate = _baseExchangeRate;
    slippageFactor = _slippageFactor;
  }

  /// @notice Calculate effective exchange rate after slippage
  /// @param amount Amount being swapped
  /// @return effectiveRate The exchange rate after slippage is applied
  function getEffectiveRate(uint256 amount) public view returns (uint256 effectiveRate) {
    // The larger the amount, the more the slippage
    // For small amounts, rate is close to baseExchangeRate
    // For large amounts, rate decreases based on slippageFactor

    // Simple quadratic slippage model:
    // effectiveRate = baseRate - (amount^2 * slippageFactor / 10^36)
    uint256 slippage = (amount * amount * slippageFactor) / 1e36;

    // Ensure we don't overflow or underflow
    if (slippage >= baseExchangeRate) {
      return 1; // Return minimal rate
    }

    return baseExchangeRate - slippage;
  }

  /// @notice Find the maximum amount that can be swapped without exceeding maxTick
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param totalAmount Total amount available to swap
  /// @return maxAmount The maximum amount that can be swapped within price limit
  function findOptimalAmount(Tick maxTick, uint256 totalAmount) public returns (uint256 maxAmount) {
    // Binary search to find the largest amount that stays within price limit
    uint256 low = 0;
    uint256 high = totalAmount;

    // Start with an initial guess
    maxAmount = 0;

    // Binary search with max 32 iterations to find optimal amount
    for (uint256 i = 0; i < 32; i++) {
      if (low >= high) break;

      uint256 mid = (low + high) / 2;
      if (mid == 0) break;

      // Calculate effective rate for this amount
      uint256 effectiveRate = getEffectiveRate(mid);
      uint256 outputAmount = (mid * effectiveRate) / 1e18;

      // Check if this amount would exceed maxTick
      Tick inferredTick = TickLib.tickFromVolumes(mid, outputAmount);

      if (Tick.unwrap(inferredTick) <= Tick.unwrap(maxTick)) {
        // This amount works, save it and try a larger one
        maxAmount = mid;
        low = mid + 1;
      } else {
        // This amount exceeds price limit, try a smaller one
        high = mid;
      }
    }

    // Emit event with calculation details
    if (maxAmount > 0) {
      uint256 finalRate = getEffectiveRate(maxAmount);
      uint256 finalOutput = (maxAmount * finalRate) / 1e18;
      Tick inferredTick = TickLib.tickFromVolumes(maxAmount, finalOutput);

      emit OptimalAmountCalculated(totalAmount, maxAmount, finalRate, Tick.unwrap(inferredTick), Tick.unwrap(maxTick));
    }

    return maxAmount;
  }

  /// @inheritdoc IExternalSwapModule
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data) external override {
    // Check that tokens match expected tokens
    require(olKey.inbound_tkn == address(inboundToken), "Inbound token mismatch");
    require(olKey.outbound_tkn == address(outboundToken), "Outbound token mismatch");

    // Get current balance of inbound token (tokens have already been sent to this contract)
    uint256 initialInboundBalance = inboundToken.balanceOf(address(this));
    uint256 initialOutboundBalance = outboundToken.balanceOf(address(this));

    // Find the maximum amount that can be swapped without exceeding maxTick
    uint256 maxAmount = findOptimalAmount(maxTick, amountToSell);

    // If we can't swap anything within the price limit, return all tokens
    if (maxAmount == 0) {
      // Return all inbound tokens to sender
      inboundToken.safeTransfer(msg.sender, amountToSell);

      // Emit event for skipped swap
      emit SwapSkipped(msg.sender, amountToSell, Tick.unwrap(maxTick), amountToSell);

      return;
    }

    // Calculate output amount for the optimal amount
    uint256 effectiveRate = getEffectiveRate(maxAmount);
    uint256 outputAmount = (maxAmount * effectiveRate) / 1e18;

    // Calculate inferred tick
    Tick inferredTick = TickLib.tickFromVolumes(maxAmount, outputAmount);

    // Double-check to ensure we're within maxTick
    require(Tick.unwrap(inferredTick) <= Tick.unwrap(maxTick), "Final tick exceeds limit");

    // Transfer output tokens to sender
    outboundToken.safeTransfer(msg.sender, outputAmount);

    // Calculate unused amount
    uint256 unusedAmount = 0;
    if (maxAmount < amountToSell) {
      unusedAmount = amountToSell - maxAmount;
      inboundToken.safeTransfer(msg.sender, unusedAmount);
    }

    // Emit event with swap details
    emit SwapExecuted(msg.sender, maxAmount, outputAmount, effectiveRate, Tick.unwrap(inferredTick), unusedAmount);
  }
}
