// SPDX-License-Identifier: MIT
import {Test, console} from "forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/interfaces/IERC20Metadata.sol";

contract BaseTest is Test {
  // Arbitrum token addresses
  IERC20 public constant WETH_ARBITRUM = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  IERC20 public constant USDC_ARBITRUM = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
  IERC20 public constant USDT_ARBITRUM = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
  IERC20 public constant WeETH_ARBITRUM = IERC20(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);
  IERC20 public constant ARB_ARBITRUM = IERC20(0x912CE59144191C1204E64559FE8253a0e49E6548);

  // Base token addresses
  IERC20 public constant WETH_BASE = IERC20(0x4200000000000000000000000000000000000006);
  IERC20 public constant USDC_BASE = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

  // Current chain tokens
  IERC20 public WETH;
  IERC20 public USDC;
  IERC20 public USDT;
  IERC20 public WeETH;
  IERC20 public ARB;

  uint256 public chainFork;

  function setUp() public virtual {
    // Default to Arbitrum if no specific chain is selected
    setArbitrumFork();
  }

  function setArbitrumFork() internal {
    string memory rpc = vm.envString("RPC_ARBITRUM");
    uint256 forkBlock = vm.envUint("FORK_BLOCK_ARBITRUM");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);

    // Set token addresses for Arbitrum
    WETH = WETH_ARBITRUM;
    USDC = USDC_ARBITRUM;
    USDT = USDT_ARBITRUM;
    WeETH = WeETH_ARBITRUM;
    ARB = ARB_ARBITRUM;
  }

  function setBaseFork() internal {
    string memory rpc = vm.envString("RPC_BASE");
    uint256 forkBlock = vm.envUint("FORK_BLOCK_BASE");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);

    // Set token addresses for Base
    WETH = WETH_BASE;
    USDC = USDC_BASE;
    USDT = IERC20(address(0)); // Not available on Base
    WeETH = IERC20(address(0)); // Not available on Base
    ARB = IERC20(address(0)); // Not available on Base
  }

  function dealTokens(address user, IERC20[] memory tokens, uint256 amount) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      if (address(tokens[i]) != address(0)) {
        // Only deal if token exists on chain
        deal(address(tokens[i]), user, amount * 10 ** IERC20Metadata(address(tokens[i])).decimals());
      }
    }
  }

  function approveTokens(address from, address to, IERC20[] memory tokens, uint256 amount) internal {
    vm.startPrank(from);
    for (uint256 i = 0; i < tokens.length; i++) {
      if (address(tokens[i]) != address(0)) {
        // Only approve if token exists on chain
        tokens[i].approve(to, 0);
        tokens[i].approve(to, amount);
      }
    }
    vm.stopPrank();
  }
}
