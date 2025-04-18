// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../BaseTest.t.sol";
import {AerodromeSwapper, Tick, TickLib} from "../../../src/modules/AerodromeSwapper.sol";
import {AerodromeSwapperWrapper} from "../../helpers/mock/AerodromeSwapperWrapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract BaseAerodromeSwapperTest is BaseTest {
  AerodromeSwapperWrapper public swapper;

  address public constant AERODROME_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
  address public constant AERODROME_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

  function setUp() public virtual override {
    chain = ForkChain.BASE;
    super.setUp();
  }

  function deployAerodromeSwapper(address ghostBook, address router) public {
    swapper = new AerodromeSwapperWrapper(ghostBook, router);
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For Aerodrome/Uniswap V2 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}
