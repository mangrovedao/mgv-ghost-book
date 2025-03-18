// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAerodromeRouter {
  struct Route {
    address from;
    address to;
    bool stable;
    address factory;
  }

  function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);
  function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);
  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    Route[] calldata routes,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}
