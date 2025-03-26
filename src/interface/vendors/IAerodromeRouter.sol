// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAerodromeRouter {
  struct Route {
    address from;
    address to;
    bool stable;
    address factory;
  }

  /// @notice Fetch and sort the reserves for a pool
  /// @param tokenA       .
  /// @param tokenB       .
  /// @param stable       True if pool is stable, false if volatile
  /// @param _factory     Address of PoolFactory for tokenA and tokenB
  /// @return reserveA    Amount of reserves of the sorted token A
  /// @return reserveB    Amount of reserves of the sorted token B
  function getReserves(address tokenA, address tokenB, bool stable, address _factory)
    external
    view
    returns (uint256 reserveA, uint256 reserveB);

  /// @notice Perform chained getAmountOut calculations on any number of pools
  function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);

  /// @notice Swap one token for another
  /// @param amountIn     Amount of token in
  /// @param amountOutMin Minimum amount of desired token received
  /// @param routes       Array of trade routes used in the swap
  /// @param to           Recipient of the tokens received
  /// @param deadline     Deadline to receive tokens
  /// @return amounts     Array of amounts returned per route
  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    Route[] calldata routes,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}
