// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISwapOperations {
  error IdenticalAddresses();
  error ReachedPoolLimit();
  error PairExists();
  error Expired();
  error PairDoesNotExist();
  error InsufficientAAmount();
  error InsufficientBAmount();
  error InsufficientInputAmount();
  error InsufficientOutputAmount();
  error InsufficientAmountADesired();
  error InsufficientAmountBDesired();
  error ExcessiveInputAmount();
  error InsufficientLiquidity();
  error InsufficientAmount();
  error InvalidPath();
  error TransferFromFailed();
  error PairRequiresStable();
  error UntrustedOracle();

  struct SwapAmount {
    uint256 amount; // including fee
    uint256 fee;
  }

  function allPairs(uint256) external view returns (address pair);

  function allPairsLength() external view returns (uint256);

  function isPair(address pair) external view returns (bool);

  function getPair(address tokenA, address tokenB) external view returns (address pair);

  function createPair(address _plainSwapPair, address tokenA, address tokenB) external;

  function getSwapBaseFee() external view returns (uint256);

  function setSwapBaseFee(uint256 _swapBaseFee) external;

  function getGovSwapFee() external view returns (uint256);

  function setGovSwapFee(uint256 _govSwapFee) external;

  function setDynamicFeeAddress(address _dynamicFee) external;

  function calcDynamicSwapFee(uint256 val) external view returns (uint256 fee);

  function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);

  function getAmountsOut(uint256 amountIn, address[] calldata path)
    external
    view
    returns (SwapAmount[] memory amounts, bool isUsablePrice);

  function getAmountsIn(uint256 amountOut, address[] calldata path)
    external
    view
    returns (SwapAmount[] memory amounts, bool isUsablePrice);

  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline,
    bytes[] memory _priceUpdateData
  ) external payable returns (SwapAmount[] memory amounts);

  function swapTokensForExactTokens(
    uint256 amountOut,
    uint256 amountInMax,
    address[] calldata path,
    address to,
    uint256 deadline,
    bytes[] memory _priceUpdateData
  ) external payable returns (SwapAmount[] memory amounts);
}
