// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../BaseTest.t.sol";
import {BalancerV2Swapper, Tick, TickLib} from "../../../src/modules/BalancerV2Swapper.sol";
import {BalancerV2SwapperWrapper} from "../../helpers/mock/BalancerV2SwapperWrapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract BaseBalancerV2SwapperTest is BaseTest {
  BalancerV2SwapperWrapper public swapper;

  address public constant JELLYSWAP_VAULT = 0xFB43069f6d0473B85686a85F4Ce4Fc1FD8F00875; // Sei
  bytes32 public constant WETH_STETH_POOL_ID = 0x3d55dea135a64e1bb8471e5eef74535a83f16f58000000000000000000000113; // SEI

  function setUp() public virtual override {
    chain = ForkChain.SEI;
    super.setUp();
  }

  function deployBalancerV2Swapper(address ghostBook) public {
    swapper = new BalancerV2SwapperWrapper(ghostBook);
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For Uniswap V2 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}
