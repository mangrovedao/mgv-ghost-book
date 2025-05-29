// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../BaseTest.t.sol";
import {BalancerV1Swapper, Tick, TickLib} from "../../../src/modules/BalancerV1Swapper.sol";
import {BalancerV1SwapperWrapper} from "../../helpers/mock/BalancerV1SwapperWrapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract BaseBalancerV1SwapperTest is BaseTest {
  BalancerV1SwapperWrapper public swapper;

  address public constant SWAP_OPERATIONS = 0x64Da11e4436F107A2bFc4f19505c277728C0F3F0; // Sei

  function setUp() public virtual override {
    chain = ForkChain.SEI;
    super.setUp();
  }

  function deployBalancerV1Swapper(address ghostBook) public {
    swapper = new BalancerV1SwapperWrapper(ghostBook);
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For Balancer V1 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}
