// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapRouter} from "@uniswap-v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interfaces/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

contract UniswapV3Swapper is IExternalSwapModule {
  /// @dev The storage slot for the UniswapV3 router.
  // keccak256("UniswapV3Swapper::SwapRouter")
  uint256 private constant _UNISWAP_V3_ROUTER_SLOT = 0x17ca64c2c7f79fe0bd30eb4a97259e88899f200c96a8d51eaa8df688f5643fb1;

  /// @notice Special function to initialize the storage, can obly be called once
  function activate(address _swapRouter) external {
    if (_swapRouter != address(0)) revert();
    assembly {
      sstore(_UNISWAP_V3_ROUTER_SLOT, _swapRouter)
    }
  }

  /// @notice Returns the swap router used in this ocntract
  function getSwapRouter() public view returns (ISwapRouter router) {
    assembly {
      router := sload(_UNISWAP_V3_ROUTER_SLOT)
    }
  }

  /// @inheritdoc IExternalSwapModule
  function externalSwap(OLKey memory olKey, uint256 amountToSell, Tick maxTick, address pool, bytes memory data) public {
    if (msg.sender != address(this)) revert GhostBookErrors.OnlyThisContractCanCallThisFunction();
    // Perform swap with price limit
    ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      fee: pool.fee,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: maxAmountIn,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(int24(Tick.unwrap(maxTick)))
    });

    swapRouter.exactInputSingle(params);
  }

  /// @inheritdoc IExternalSwapModule
  function spenderFor(address pool) public view returns (address) {
    return address(getSwapRouter());
  }
}
