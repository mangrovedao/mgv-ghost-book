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
  IERC20 public constant DAI_ARBITRUM = IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);

  // Base token addresses
  IERC20 public constant WETH_BASE = IERC20(0x4200000000000000000000000000000000000006);
  IERC20 public constant USDC_BASE = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
  IERC20 public constant DAI_BASE = IERC20(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);
  IERC20 public constant USDT_BASE = IERC20(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);

  // Sei token addresses
  IERC20 public constant WETH_SEI = IERC20(0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7);
  IERC20 public constant USDT_SEI = IERC20(0x9151434b16b9763660705744891fA906F660EcC5);
  IERC20 public constant jUSDv1_SEI = IERC20(0x4c6Dd2CA85Ca55C4607Cd66A7EBdD2C9b58112Cf);
  IERC20 public constant jTSLAv1_SEI = IERC20(0x412621a1ff7a11A794DE81085Dc3C16777a664e2);

  // Current chain tokens
  IERC20 public WETH;
  IERC20 public USDC;
  IERC20 public USDT;
  IERC20 public WeETH;
  IERC20 public ARB;
  IERC20 public DAI;

  enum ForkChain {
    BASE,
    ARBITRUM,
    SEI
  }

  uint256 public chainFork;
  ForkChain public chain;

  function setUp() public virtual {
    if (chain == ForkChain.BASE) {
      setBaseFork();
    }
    if (chain == ForkChain.ARBITRUM) {
      setArbitrumFork();
    }
    if (chain == ForkChain.SEI) {
      setSeiFork();
    }
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
    DAI = DAI_ARBITRUM;
  }

  function setBaseFork() internal {
    string memory rpc = vm.envString("RPC_BASE");
    uint256 forkBlock = vm.envUint("FORK_BLOCK_BASE");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);

    // Set token addresses for Base
    WETH = WETH_BASE;
    USDC = USDC_BASE;
    USDT = USDT_BASE; // Not available on Base
    WeETH = IERC20(address(0)); // Not available on Base
    ARB = IERC20(address(0)); // Not available on Base
    DAI = DAI_BASE;
  }

  function setSeiFork() internal {
    string memory rpc = vm.envString("RPC_SEI");
    uint256 forkBlock = vm.envUint("FORK_BLOCK_SEI");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);

    // Set token addresses for Sei
    WETH = WETH_SEI;
    USDC = IERC20(address(0));
    USDT = USDT_SEI;
    WeETH = IERC20(address(0));
    ARB = IERC20(address(0));
    DAI = IERC20(address(0));
  }

  function dealTokens(address user, IERC20[] memory tokens, uint256 amount) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      if (address(tokens[i]) != address(0)) {
        // Only deal if token exists on chain
        deal(address(tokens[i]), user, amount * 10_000 ** IERC20Metadata(address(tokens[i])).decimals());
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

  function extractCalldata(bytes memory calldataWithSelector) internal pure returns (bytes memory) {
    bytes memory calldataWithoutSelector;

    require(calldataWithSelector.length >= 4);

    assembly {
      let totalLength := mload(calldataWithSelector)
      let targetLength := sub(totalLength, 4)
      calldataWithoutSelector := mload(0x40)

      // Set the length of callDataWithoutSelector (initial length - 4)
      mstore(calldataWithoutSelector, targetLength)

      // Mark the memory space taken for callDataWithoutSelector as allocated
      mstore(0x40, add(calldataWithoutSelector, add(0x20, targetLength)))

      // Process first 32 bytes (we only take the last 28 bytes)
      mstore(add(calldataWithoutSelector, 0x20), shl(0x20, mload(add(calldataWithSelector, 0x20))))

      // Process all other data by chunks of 32 bytes
      for { let i := 0x1C } lt(i, targetLength) { i := add(i, 0x20) } {
        mstore(add(add(calldataWithoutSelector, 0x20), i), mload(add(add(calldataWithSelector, 0x20), add(i, 0x04))))
      }
    }

    return calldataWithoutSelector;
  }
}
