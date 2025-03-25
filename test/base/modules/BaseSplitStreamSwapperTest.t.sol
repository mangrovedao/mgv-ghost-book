// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../BaseTest.t.sol";
import {SplitStreamSwapper} from "../../../src/modules/SplitStreamSwapper.sol";
import {SplitStreamSwapperWrapper} from "../../helpers/mock/SplitStreamSwapperWrapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

contract BaseSplitStreamSwapperTest is BaseTest {
  SplitStreamSwapperWrapper public swapper;

  address public constant SPLITSTREAM_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
  address public constant SPLITSTREAM_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

  function setUp() public virtual override {
    chain = ForkChain.BASE;
    super.setUp();
  }

  function deploySplitStreamSwapper(address ghostBook) public {
    swapper = new SplitStreamSwapperWrapper(ghostBook);
  }

  // Helper to convert from SplitStream tick to Mangrove tick
  function _convertToMgvTick(address inbound, address outbound, int24 uniTick) internal pure returns (int24) {
    return inbound < outbound ? -uniTick : uniTick;
  }
}
