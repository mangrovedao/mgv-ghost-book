// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BalancerV2Swapper} from "src/modules/BalancerV2Swapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

contract BalancerV2SwapperWrapper is BalancerV2Swapper {
  constructor(address gb) BalancerV2Swapper(gb) {}

  function approve(IERC20 token, address spender, uint256 amount) public {
    token.approve(spender, amount);
  }

  // Updated to match the new struct-based function signature
  function calculateAmountOut(
    BalancerV2Swapper.SwapParams memory swapParams,
    BalancerV2Swapper.AssetConfig memory assetConfig
  ) public returns (uint256) {
    // Create the CalculateAmountParams struct that the internal function expects
    BalancerV2Swapper.CalculateAmountParams memory calcParams = BalancerV2Swapper.CalculateAmountParams({
      vault: swapParams.vault,
      poolId: swapParams.poolId,
      assets: assetConfig.assets,
      assetInIndex: assetConfig.assetInIndex,
      assetOutIndex: assetConfig.assetOutIndex,
      amountIn: swapParams.actualAmountToSell
    });

    return _calculateAmountOut(calcParams);
  }

  // Helper function to create sorted assets (exposing internal function for testing)
  function createSortedAssets(address token0, address token1) public pure returns (address[] memory) {
    return _createSortedAssets(token0, token1);
  }

  // Helper function to get asset indices (exposing internal function for testing)
  function getAssetIndices(address[] memory assets, address inToken, address outToken)
    public
    pure
    returns (uint256 assetInIndex, uint256 assetOutIndex)
  {
    return _getAssetIndices(assets, inToken, outToken);
  }
}
