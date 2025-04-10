// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveGhostBook, ModuleData} from "../MangroveGhostBook.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {ReentrancyGuard} from "@openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {GhostBookEvents} from "../libraries/GhostBookEvents.sol";

/// @title MultiModuleData - Module data with priority-based execution
/// @notice Structure to define a prioritized list of modules to use sequentially
struct MultiModuleData {
  /// @notice Array of modules to use for the swap (in priority order)
  ModuleData[] modules;
}

/// @title OrderResults - Struct for storing the results of order execution
/// @notice Used to avoid stack too deep errors by grouping related values
struct OrderResults {
  uint256[] amountsGot;
  uint256[] amountsGave;
  address[] moduleAddresses;
  uint256 takerGot;
  uint256 takerGave;
  uint256 bounty;
  uint256 feePaid;
  uint256 unusedAmount;
}

/// @title MultiModuleGhostBook - GhostBook extension for sequential module execution
/// @notice Extends MangroveGhostBook to route swaps through multiple external modules in priority order
/// @dev All modules must be whitelisted in the parent contract
contract MultiModuleGhostBook is MangroveGhostBook {
  using SafeERC20 for IERC20;

  /// @notice Emitted when a multi-module order is executed
  event ModuleOrderExecuted(
    address indexed taker, bytes32 indexed olKeyHash, address[] modules, uint256[] amountsGot, uint256[] amountsGave
  );

  /// @notice Constructor inherits from MangroveGhostBook
  /// @param _mgv The address of the Mangrove contract
  constructor(address _mgv) MangroveGhostBook(_mgv) {}

  /// @notice Error thrown when empty module array is provided
  error EmptyModuleArray();

  /// @notice Public interface for executing a market order with multiple modules in priority order
  /// @param olKey The offer list key containing token pair and tick spacing
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Amount of input tokens to sell
  /// @param moduleData Data structure containing prioritized list of modules
  /// @return takerGot Total amount of output tokens received
  /// @return takerGave Total amount of input tokens spent
  /// @return bounty Bounty received from failed offers
  /// @return feePaid Fees paid to Mangrove
  function marketOrderByTickMultiModule(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata moduleData
  ) public nonReentrant returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) {
    // Validate module data
    _validateModuleData(moduleData);

    // Start order execution
    emit GhostBookEvents.OrderStarted(
      msg.sender,
      olKey.hash(),
      address(0), // No single module
      maxTick,
      amountToSell,
      false
    );

    // Transfer tokens from taker to this contract
    IERC20(olKey.inbound_tkn).safeTransferFrom(msg.sender, address(this), amountToSell);

    // Create struct to store all results and avoid stack too deep errors
    OrderResults memory results = _createOrderResults(moduleData.modules.length);

    // Execute the order and populate results
    _executeOrder(olKey, maxTick, amountToSell, moduleData, results);

    // Return unused tokens and results to taker
    _returnTokensToTaker(
      olKey.inbound_tkn, olKey.outbound_tkn, amountToSell, results.takerGot, results.takerGave, results.bounty
    );

    // Emit events for order completion
    _emitOrderEvents(
      olKey.hash(),
      results.moduleAddresses,
      results.amountsGot,
      results.amountsGave,
      results.takerGot,
      results.takerGave,
      results.bounty,
      results.feePaid
    );

    return (results.takerGot, results.takerGave, results.bounty, results.feePaid);
  }

  /// @notice Initialize an OrderResults struct with the right array lengths
  /// @param numModules Number of modules to allocate arrays for
  /// @return results Initialized OrderResults struct
  function _createOrderResults(uint256 numModules) internal pure returns (OrderResults memory results) {
    results.amountsGot = new uint256[](numModules);
    results.amountsGave = new uint256[](numModules);
    results.moduleAddresses = new address[](numModules);

    // Other fields default to 0
    return results;
  }

  /// @notice Main order execution logic
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Amount of input tokens to sell
  /// @param moduleData Data structure with prioritized modules
  /// @param results Struct to store all order execution results
  function _executeOrder(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata moduleData,
    OrderResults memory results
  ) internal {
    // Execute swaps via external modules in sequence
    uint256 remainingAmount = _executeExternalSwapsInSequence(olKey, maxTick, amountToSell, moduleData, results);

    // Store unused amount for potential Mangrove fallback
    results.unusedAmount = remainingAmount;

    // If there's any amount left, route through Mangrove
    if (results.unusedAmount > 0) {
      _executeMangroveSwap(olKey, maxTick, results.unusedAmount, results);
    }

    // Sum up total amounts got and gave from modules
    (results.takerGot, results.takerGave) =
      _aggregateResults(results.takerGot, results.takerGave, results.amountsGot, results.amountsGave);
  }

  /// @notice Override the externalSwap function to handle direct transfers
  /// @param olKey The offer list key
  /// @param amountToSell Amount to sell
  /// @param maxTick Maximum acceptable price
  /// @param moduleData External module information
  /// @param taker Address that initiated the swap
  /// @return gave Amount spent
  /// @return got Amount received
  function externalSwap(
    OLKey memory olKey,
    uint256 amountToSell,
    Tick maxTick,
    ModuleData calldata moduleData,
    address taker
  ) public override returns (uint256 gave, uint256 got) {
    if (msg.sender != address(this)) revert GhostBookErrors.OnlyThisContractCanCallThisFunction();
    if (!whitelistedModules[moduleData.module]) revert GhostBookErrors.ModuleNotWhitelisted();

    Tick externalMaxTick = _getExternalSwapTick(olKey, maxTick);

    // Store initial balances to compare after swap
    uint256 initialInbound = IERC20(olKey.inbound_tkn).balanceOf(address(this));
    uint256 initialOutbound = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Transfer tokens from this contract to the module (instead of from taker)
    IERC20(olKey.inbound_tkn).safeTransfer(address(moduleData.module), amountToSell);

    // Execute the swap on the module
    moduleData.module.externalSwap(olKey, amountToSell, externalMaxTick, moduleData.data);

    // Calculate actual amounts from balance differences
    uint256 finalInbound = IERC20(olKey.inbound_tkn).balanceOf(address(this));
    uint256 finalOutbound = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Calculate amounts based on balance differences
    gave = initialInbound - finalInbound;
    got = finalOutbound - initialOutbound;

    // Verify price is within limits
    if (gave > 0 && got > 0) {
      Tick inferredTick = TickLib.tickFromVolumes(gave, got);
      if (Tick.unwrap(inferredTick) > Tick.unwrap(maxTick)) {
        revert GhostBookErrors.InferredTickHigherThanMaxTick(inferredTick, maxTick);
      }
    }

    return (gave, got);
  }

  /// @notice Executes swaps through external modules in sequence until all amount is used or modules are exhausted
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param amountToSell Total amount to sell
  /// @param moduleData Data structure with prioritized modules
  /// @param results Struct to store order execution results
  /// @return remainingAmount Amount left unused after going through all modules
  function _executeExternalSwapsInSequence(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    MultiModuleData calldata moduleData,
    OrderResults memory results
  ) internal returns (uint256 remainingAmount) {
    ModuleData[] memory modules = moduleData.modules;
    remainingAmount = amountToSell;

    // Try each module in sequence until remaining amount is 0 or all modules are tried
    for (uint256 i = 0; i < modules.length && remainingAmount > 0; i++) {
      // Skip modules that aren't whitelisted
      if (!whitelistedModules[modules[i].module]) {
        results.moduleAddresses[i] = address(modules[i].module);
        continue;
      }

      // Store module address for event
      results.moduleAddresses[i] = address(modules[i].module);

      // Try to execute swap with current module
      try this.externalSwap(olKey, remainingAmount, maxTick, modules[i], msg.sender) returns (uint256 gave, uint256 got)
      {
        // Record amounts got and gave for this module
        results.amountsGot[i] = got;
        results.amountsGave[i] = gave;

        // Update remaining amount for next module
        remainingAmount -= gave;
      } catch {
        // On failure, record zero amounts for this module
        results.amountsGot[i] = 0;
        results.amountsGave[i] = 0;
      }

      // Reset token approvals
      IERC20(olKey.inbound_tkn).forceApprove(address(modules[i].module), 0);
    }

    return remainingAmount;
  }

  /// @notice Executes a swap through Mangrove
  /// @param olKey The offer list key
  /// @param maxTick Maximum price (as a tick) willing to pay
  /// @param unusedAmount Amount to swap
  /// @param results Struct to store order execution results
  function _executeMangroveSwap(OLKey memory olKey, Tick maxTick, uint256 unusedAmount, OrderResults memory results)
    internal
  {
    // Approve MGV to spend the remaining tokens
    IERC20(olKey.inbound_tkn).forceApprove(address(MGV), unusedAmount);

    // Execute Mangrove order
    (uint256 takerGotFromMgv, uint256 takerGaveToMgv, uint256 bounty, uint256 feePaid) =
      MGV.marketOrderByTick(olKey, maxTick, unusedAmount, false);

    // Update results struct with Mangrove values
    results.bounty = bounty;
    results.feePaid = feePaid;
    results.takerGot += takerGotFromMgv;
    results.takerGave += takerGaveToMgv;

    // Revoke approval
    IERC20(olKey.inbound_tkn).forceApprove(address(MGV), 0);
  }

  /// @notice Aggregates results from all modules
  /// @param initialGot Initial amount received (from Mangrove)
  /// @param initialGave Initial amount spent (through Mangrove)
  /// @param amountsGot Array of amounts received from external modules
  /// @param amountsGave Array of amounts spent through external modules
  /// @return totalGot Total amount received
  /// @return totalGave Total amount spent
  function _aggregateResults(
    uint256 initialGot,
    uint256 initialGave,
    uint256[] memory amountsGot,
    uint256[] memory amountsGave
  ) internal pure returns (uint256 totalGot, uint256 totalGave) {
    totalGot = initialGot;
    totalGave = initialGave;

    for (uint256 i = 0; i < amountsGot.length; i++) {
      totalGot += amountsGot[i];
      totalGave += amountsGave[i];
    }

    return (totalGot, totalGave);
  }

  /// @notice Returns tokens to the taker after execution
  /// @param inboundToken Inbound token address
  /// @param outboundToken Outbound token address
  /// @param amountToSell Original amount intended to sell
  /// @param takerGot Total amount received
  /// @param takerGave Total amount spent
  /// @param bounty Bounty received from failed offers
  function _returnTokensToTaker(
    address inboundToken,
    address outboundToken,
    uint256 amountToSell,
    uint256 takerGot,
    uint256 takerGave,
    uint256 bounty
  ) internal {
    // Return unused tokens
    uint256 inboundToReturn = amountToSell - takerGave;
    if (inboundToReturn > 0) {
      IERC20(inboundToken).safeTransfer(msg.sender, inboundToReturn);
    }

    if (takerGot > 0) {
      IERC20(outboundToken).safeTransfer(msg.sender, takerGot);
    }

    if (bounty > 0) {
      (bool success,) = payable(msg.sender).call{value: bounty}("");
      if (!success) revert GhostBookErrors.TransferFailed();
    }
  }

  /// @notice Emits events for order completion
  /// @param olKeyHash Hash of the offer list key
  /// @param moduleAddresses Array of module addresses used
  /// @param amountsGot Array of amounts received from each module
  /// @param amountsGave Array of amounts spent through each module
  /// @param takerGot Total amount received
  /// @param takerGave Total amount spent
  /// @param bounty Bounty received from failed offers
  /// @param feePaid Fees paid to Mangrove
  function _emitOrderEvents(
    bytes32 olKeyHash,
    address[] memory moduleAddresses,
    uint256[] memory amountsGot,
    uint256[] memory amountsGave,
    uint256 takerGot,
    uint256 takerGave,
    uint256 bounty,
    uint256 feePaid
  ) internal {
    // Emit detailed breakdown event
    emit ModuleOrderExecuted(msg.sender, olKeyHash, moduleAddresses, amountsGot, amountsGave);

    // Emit standard order completion event
    emit GhostBookEvents.OrderCompleted(msg.sender, olKeyHash, takerGot, takerGave, bounty, feePaid);
  }

  /// @notice Validates the module data structure
  /// @param moduleData The module data to validate
  function _validateModuleData(MultiModuleData calldata moduleData) internal view {
    // Ensure modules array is not empty
    if (moduleData.modules.length == 0) {
      revert EmptyModuleArray();
    }

    // Verify first module is whitelisted (others will be checked during execution)
    if (!whitelistedModules[moduleData.modules[0].module]) {
      revert GhostBookErrors.ModuleNotWhitelisted();
    }
  }
}
