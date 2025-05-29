// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {ISwapRouterV2} from "../interface/vendors/ISwapRouterV2.sol";
import {TickMath} from "@uniswap-v3-core/contracts/libraries/TickMath.sol";
import {IExternalSwapModule} from "../interface/IExternalSwapModule.sol";
import {GhostBookErrors} from "../libraries/GhostBookErrors.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UniswapV3Swapper - A generalized Uniswap V3 integration to perform limit order swaps in any Uniswap V3 implementation.
/// @notice This contract serves as a plugin for the core contract {GhostBook}
contract UniswapV3Swapper is IExternalSwapModule {
  using SafeERC20 for IERC20;

  error RouterAlreadySet();
  error Unauthorized();
  error DivFailed();

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
    virtual
    onlyGhostBook
  {
    // Decode needed data for the swap
    (address router, uint24 fee) = abi.decode(data, (address, uint24));

    IERC20(olKey.inbound_tkn).forceApprove(address(router), amountToSell);

    // Adjust tick after fees for Uniswap
    int24 uniswapTick = _adjustTickForUniswap(olKey.inbound_tkn, olKey.outbound_tkn, maxTick, fee);

    // Validate price limit is within bounds
    uint160 sqrtPriceLimitX96 = TickMath.getSqrtRatioAtTick(uniswapTick);

    // Store initial balances to compare after swap
    uint256 gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - amountToSell;

    uint256 got = IERC20(olKey.outbound_tkn).balanceOf(address(this));

    // Perform swap with price limit
    ISwapRouterV2.ExactInputSingleParams memory params = ISwapRouterV2.ExactInputSingleParams({
      tokenIn: olKey.inbound_tkn,
      tokenOut: olKey.outbound_tkn,
      fee: fee,
      recipient: address(this),
      amountIn: amountToSell,
      amountOutMinimum: 0,
      sqrtPriceLimitX96: sqrtPriceLimitX96
    });

    ISwapRouterV2(router).exactInputSingle(params);
    // Calculate actual amounts from balance differences
    gave = IERC20(olKey.inbound_tkn).balanceOf(address(this)) - gave;
    got = IERC20(olKey.outbound_tkn).balanceOf(address(this)) - got;

    // Transfer tokens back
    IERC20(olKey.inbound_tkn).forceApprove(address(router), 0);
    IERC20(olKey.inbound_tkn).safeTransfer(msg.sender, gave);
    IERC20(olKey.outbound_tkn).safeTransfer(msg.sender, got);
  }

  /// @dev Helper function to convert from Mangrove tick to Uniswap tick as prices are represented differently
  /// @param inboundToken The inbound token address
  /// @param outboundToken The outbound token address
  /// @param maxTick The maximum tick
  /// @param feePips The fee pips
  /// @return The adjusted tick
  function _adjustTickForUniswap(address inboundToken, address outboundToken, Tick maxTick, uint24 feePips)
    internal
    pure
    returns (int24)
  {
    int24 mgvTick = int24(Tick.unwrap(maxTick)) - int24(uint24(divUp(uint256(feePips), 100)));
    int24 uniTick = inboundToken < outboundToken ? -mgvTick : mgvTick;

    return uniTick;
  }

  /// @dev source: https://github.com/Vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol
  /// @dev Returns `ceil(x / d)`.
  /// Reverts if `d` is zero.
  function divUp(uint256 x, uint256 d) internal pure returns (uint256 z) {
    /// @solidity memory-safe-assembly
    assembly {
      if iszero(d) {
        mstore(0x00, 0x65244e4e) // `DivFailed()`.
        revert(0x1c, 0x04)
      }
      z := add(iszero(iszero(mod(x, d))), div(x, d))
    }
  }
}
