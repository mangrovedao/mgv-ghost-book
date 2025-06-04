// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IBalancerV2Vault as IVault} from "../interface/vendors/IBalancerV2Vault.sol";

/// @title BalancerV2Swapper - A generalized Balancer V2 integration to perform limit order swaps in any Balancer V2 fork
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract BalancerV2Swapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error VaultNotSet();
  error Unauthorized();
  error PriceExceedsLimit();

  address public immutable ghostBook;

  /// @dev Struct to hold swap parameters to avoid too many parameters
  struct SwapParams {
    address vault;
    bytes32 poolId;
    uint256 deadline;
    address inToken;
    address outToken;
    uint256 actualAmountToSell;
    Tick maxTick;
  }

  /// @dev Struct to hold asset configuration
  struct AssetConfig {
    address[] assets;
    uint256 assetInIndex;
    uint256 assetOutIndex;
  }

  /// @dev Struct for executeBalancerSwap parameters
  struct ExecuteSwapParams {
    address vault;
    bytes32 poolId;
    address[] assets;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    uint256 amountIn;
    uint256 deadline;
    Tick maxTick;
  }

  /// @dev Struct for calculateAmountOut parameters
  struct CalculateAmountParams {
    address vault;
    bytes32 poolId;
    address[] assets;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    uint256 amountIn;
  }

  /// @dev Struct for findMaxSwapAmount parameters
  struct FindMaxAmountParams {
    address vault;
    bytes32 poolId;
    address[] assets;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    Tick maxTick;
    uint256 initialAmount;
  }

  // Events for better debugging
  event SwapExecuted(
    address indexed inToken, address indexed outToken, uint256 amountIn, uint256 amountOut, bytes32 poolId
  );

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
    SwapParams memory params = _initializeSwapParams(olKey, amountToSell, maxTick, data);

    if (!_validateSwapPreconditions(params)) {
      return;
    }

    AssetConfig memory assetConfig = _prepareAssetConfiguration(params.inToken, params.outToken);

    uint256 finalSwapAmount = _calculateOptimalSwapAmount(params, assetConfig);

    if (finalSwapAmount > 0) {
      ExecuteSwapParams memory executeParams = ExecuteSwapParams({
        vault: params.vault,
        poolId: params.poolId,
        assets: assetConfig.assets,
        assetInIndex: assetConfig.assetInIndex,
        assetOutIndex: assetConfig.assetOutIndex,
        amountIn: finalSwapAmount,
        deadline: params.deadline,
        maxTick: params.maxTick
      });

      _executeBalancerSwap(executeParams);
    }
  }

  /// @dev Initialize swap parameters from input data
  function _initializeSwapParams(OLKey memory olKey, uint256 amountToSell, Tick maxTick, bytes memory data)
    internal
    view
    returns (SwapParams memory params)
  {
    (address vault, bytes32 poolId, uint256 deadline) = abi.decode(data, (address, bytes32, uint256));

    if (vault == address(0)) {
      revert VaultNotSet();
    }

    uint256 availableBalance = IERC20(olKey.inbound_tkn).balanceOf(address(this));

    params = SwapParams({
      vault: vault,
      poolId: poolId,
      deadline: deadline,
      inToken: olKey.inbound_tkn,
      outToken: olKey.outbound_tkn,
      actualAmountToSell: amountToSell > availableBalance ? availableBalance : amountToSell,
      maxTick: maxTick
    });
  }

  /// @dev Validate basic preconditions for the swap
  function _validateSwapPreconditions(SwapParams memory params) internal view returns (bool) {
    uint256 availableBalance = IERC20(params.inToken).balanceOf(address(this));
    return availableBalance > 0 && params.actualAmountToSell > 0;
  }

  /// @dev Prepare asset configuration (sorted assets and indices)
  function _prepareAssetConfiguration(address inToken, address outToken)
    internal
    pure
    returns (AssetConfig memory config)
  {
    config.assets = _createSortedAssets(inToken, outToken);
    (config.assetInIndex, config.assetOutIndex) = _getAssetIndices(config.assets, inToken, outToken);
  }

  /// @dev Calculate optimal swap amount considering price limits
  function _calculateOptimalSwapAmount(SwapParams memory params, AssetConfig memory assetConfig)
    internal
    returns (uint256 swapAmount)
  {
    swapAmount = params.actualAmountToSell;

    CalculateAmountParams memory calcParams = CalculateAmountParams({
      vault: params.vault,
      poolId: params.poolId,
      assets: assetConfig.assets,
      assetInIndex: assetConfig.assetInIndex,
      assetOutIndex: assetConfig.assetOutIndex,
      amountIn: swapAmount
    });

    uint256 expectedOutput = _calculateAmountOut(calcParams);

    if (expectedOutput == 0) {
      return 0; // No liquidity available
    }

    Tick estimatedTick = TickLib.tickFromVolumes(swapAmount, expectedOutput);

    // If estimated price exceeds limit, find maximum acceptable amount
    if (Tick.unwrap(estimatedTick) > Tick.unwrap(params.maxTick)) {
      FindMaxAmountParams memory findMaxParams = FindMaxAmountParams({
        vault: params.vault,
        poolId: params.poolId,
        assets: assetConfig.assets,
        assetInIndex: assetConfig.assetInIndex,
        assetOutIndex: assetConfig.assetOutIndex,
        maxTick: params.maxTick,
        initialAmount: swapAmount
      });

      swapAmount = _findMaxSwapAmount(findMaxParams);
    }
  }

  /// @dev Execute the actual Balancer V2 swap using batchSwap
  function _executeBalancerSwap(ExecuteSwapParams memory params) internal {
    uint256 initialInbound = IERC20(params.assets[params.assetInIndex]).balanceOf(address(this));
    uint256 initialOutbound = IERC20(params.assets[params.assetOutIndex]).balanceOf(address(this));

    // Approve vault to spend tokens
    IERC20(params.assets[params.assetInIndex]).forceApprove(params.vault, params.amountIn);

    // Create the swap step
    IVault.BatchSwapStep[] memory swaps = new IVault.BatchSwapStep[](1);
    swaps[0] = IVault.BatchSwapStep({
      poolId: params.poolId,
      assetInIndex: params.assetInIndex,
      assetOutIndex: params.assetOutIndex,
      amount: params.amountIn,
      userData: ""
    });

    // Fund management
    IVault.FundManagement memory funds = IVault.FundManagement({
      sender: address(this),
      fromInternalBalance: false,
      recipient: payable(address(this)),
      toInternalBalance: false
    });

    // Set limits - positive for assets we're sending, negative for assets we're receiving
    int256[] memory limits = new int256[](params.assets.length);
    limits[params.assetInIndex] = int256(params.amountIn); // Max amount we're willing to send
    limits[params.assetOutIndex] = -1; // We want to receive at least something (will be checked by price limit)

    try IVault(params.vault).batchSwap(IVault.SwapKind.GIVEN_IN, swaps, params.assets, funds, limits, params.deadline)
    returns (int256[] memory deltas) {
      // Calculate actual amounts from balance differences
      uint256 actualInbound = IERC20(params.assets[params.assetInIndex]).balanceOf(address(this));
      uint256 actualOutbound = IERC20(params.assets[params.assetOutIndex]).balanceOf(address(this));

      uint256 gave = initialInbound - actualInbound;
      uint256 got = actualOutbound - initialOutbound;

      // Verify price is within limits
      if (gave > 0 && got > 0) {
        Tick inferredTick = TickLib.tickFromVolumes(gave, got);
        if (Tick.unwrap(inferredTick) > Tick.unwrap(params.maxTick)) {
          revert PriceExceedsLimit();
        }
      }

      // Return tokens to GhostBook
      _returnTokens(params.vault, params.assets[params.assetInIndex], params.assets[params.assetOutIndex], got);
    } catch {
      // If swap fails, clean up and return tokens
      _returnTokens(params.vault, params.assets[params.assetInIndex], params.assets[params.assetOutIndex], 0);
    }
  }

  /// @dev Calculate amount out for a single swap using queryBatchSwap
  function _calculateAmountOut(CalculateAmountParams memory params) internal returns (uint256 amountOut) {
    if (params.amountIn == 0) return 0;

    // Create the swap step
    IVault.BatchSwapStep[] memory swaps = new IVault.BatchSwapStep[](1);
    swaps[0] = IVault.BatchSwapStep({
      poolId: params.poolId,
      assetInIndex: params.assetInIndex,
      assetOutIndex: params.assetOutIndex,
      amount: params.amountIn,
      userData: ""
    });

    // Fund management (not used in query, but required)
    IVault.FundManagement memory funds = IVault.FundManagement({
      sender: address(this),
      fromInternalBalance: false,
      recipient: payable(address(this)),
      toInternalBalance: false
    });

    try IVault(params.vault).queryBatchSwap(IVault.SwapKind.GIVEN_IN, swaps, params.assets, funds) returns (
      int256[] memory deltas
    ) {
      // deltas[assetOutIndex] will be negative (amount out)
      // We return the absolute value
      if (deltas[params.assetOutIndex] >= 0) {
        return 0; // Invalid result
      }
      amountOut = uint256(-deltas[params.assetOutIndex]);
    } catch {
      return 0; // Query failed, no liquidity or invalid pool
    }
  }

  /// @dev Find the maximum amount that can be swapped within the price limit
  function _findMaxSwapAmount(FindMaxAmountParams memory params) internal returns (uint256 maxAmount) {
    uint256 low = 0;
    uint256 high = params.initialAmount;
    uint256 bestAmount = 0;

    // Binary search with a maximum of 10 iterations for better precision
    for (uint256 i = 0; i < 10; i++) {
      if (low >= high) break;

      uint256 mid = (low + high + 1) / 2; // Avoid infinite loop
      if (mid == 0) break;

      CalculateAmountParams memory calcParams = CalculateAmountParams({
        vault: params.vault,
        poolId: params.poolId,
        assets: params.assets,
        assetInIndex: params.assetInIndex,
        assetOutIndex: params.assetOutIndex,
        amountIn: mid
      });

      uint256 expectedOutput = _calculateAmountOut(calcParams);

      if (expectedOutput == 0) {
        // No liquidity for this amount, try smaller
        high = mid - 1;
        continue;
      }

      Tick estimatedTick = TickLib.tickFromVolumes(mid, expectedOutput);

      if (Tick.unwrap(estimatedTick) <= Tick.unwrap(params.maxTick)) {
        // This amount works, try a larger one
        bestAmount = mid;
        low = mid + 1;
      } else {
        // This amount exceeds price limit, try a smaller one
        high = mid - 1;
      }
    }
    return bestAmount;
  }

  /// @dev Create a sorted assets array for Balancer
  function _createSortedAssets(address token0, address token1) internal pure returns (address[] memory assets) {
    assets = new address[](2);
    if (token0 < token1) {
      assets[0] = token0;
      assets[1] = token1;
    } else {
      assets[0] = token1;
      assets[1] = token0;
    }
  }

  /// @dev Get the indices of input and output tokens in the sorted assets array
  function _getAssetIndices(address[] memory assets, address inToken, address outToken)
    internal
    pure
    returns (uint256 assetInIndex, uint256 assetOutIndex)
  {
    for (uint256 i = 0; i < assets.length; i++) {
      if (assets[i] == inToken) {
        assetInIndex = i;
      } else if (assets[i] == outToken) {
        assetOutIndex = i;
      }
    }
  }

  /// @dev Return tokens back to the caller
  function _returnTokens(address vault, address inToken, address outToken, uint256 gotAmount) internal {
    // Reset approval
    IERC20(inToken).forceApprove(vault, 0);

    // Return any remaining input tokens
    uint256 remainingInToken = IERC20(inToken).balanceOf(address(this));
    if (remainingInToken > 0) {
      IERC20(inToken).safeTransfer(ghostBook, remainingInToken);
    }

    // Return output tokens if any
    if (gotAmount > 0) {
      IERC20(outToken).safeTransfer(ghostBook, gotAmount);
    }
  }
}
