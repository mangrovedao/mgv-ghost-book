interface IBalancerV2Vault {
  enum PoolSpecialization {
    GENERAL,
    MINIMAL_SWAP_INFO,
    TWO_TOKEN
  }

  enum PoolBalanceChangeKind {
    JOIN,
    EXIT
  }

  enum SwapKind {
    GIVEN_IN,
    GIVEN_OUT
  }

  function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256 deadline)
    external
    payable
    returns (uint256);

  struct SingleSwap {
    bytes32 poolId;
    SwapKind kind;
    address assetIn;
    address assetOut;
    uint256 amount;
    bytes userData;
  }

  function batchSwap(
    SwapKind kind,
    BatchSwapStep[] memory swaps,
    address[] memory assets,
    FundManagement memory funds,
    int256[] memory limits,
    uint256 deadline
  ) external payable returns (int256[] memory);

  struct BatchSwapStep {
    bytes32 poolId;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    uint256 amount;
    bytes userData;
  }

  struct FundManagement {
    address sender;
    bool fromInternalBalance;
    address payable recipient;
    bool toInternalBalance;
  }

  function queryBatchSwap(
    SwapKind kind,
    BatchSwapStep[] memory swaps,
    address[] memory assets,
    FundManagement memory funds
  ) external returns (int256[] memory assetDeltas);
}
