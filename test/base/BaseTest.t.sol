// SPDX-License-Identifier: MIT
import {Test, console} from "forge-std/src/Test.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

contract BaseTest is Test {
  IERC20 public WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
  IERC20 public USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
  IERC20 public USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
  IERC20 public WeETH = IERC20(0x35751007a407ca6FEFfE80b3cB397736D2cf4dbe);

  uint256 public chainFork;

  function setUp() public virtual {
    string memory rpc = vm.envString("RPC_ARBITRUM");
    uint256 forkBlock = vm.envUint("FORK_BLOCK");
    chainFork = vm.createSelectFork(rpc);
    vm.rollFork(forkBlock);
  }
}
