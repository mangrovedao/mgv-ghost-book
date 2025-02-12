// SPDX-License-Identifier: MIT
import {Test, console} from "forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/interfaces/IERC20Metadata.sol";

contract BaseTest is Test {
  IERC20 public WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  IERC20 public USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
  IERC20 public USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
  IERC20 public WeETH = IERC20(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);
  IERC20 public ARB = IERC20(0x912CE59144191C1204E64559FE8253a0e49E6548);

  uint256 public chainFork;

  function setUp() public virtual {
    string memory rpc = vm.envString("RPC_ARBITRUM");
    uint256 forkBlock = vm.envUint("FORK_BLOCK");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);
  }

  function dealTokens(address user, IERC20[] memory tokens, uint256 amount) internal {
    for (uint256 i = 0; i < tokens.length; i++) {
      deal(address(tokens[i]), user, amount * 10 ** IERC20Metadata(address(tokens[i])).decimals());
    }
  }

  function approveTokens(address from, address to, IERC20[] memory tokens, uint256 amount) internal {
    vm.startPrank(from);
    for (uint256 i = 0; i < tokens.length; i++) {
      tokens[i].approve(to, 0);
      tokens[i].approve(to, amount);
    }
    vm.stopPrank();
  }
}
