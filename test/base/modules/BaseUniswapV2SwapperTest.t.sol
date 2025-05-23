// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../BaseTest.t.sol";
import {UniswapV2Swapper, Tick, TickLib} from "../../../src/modules/UniswapV2Swapper.sol";
import {UniswapV2SwapperWrapper} from "../../helpers/mock/UniswapV2SwapperWrapper.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract BaseUniswapV2SwapperTest is BaseTest {
  UniswapV2SwapperWrapper public swapper;

  address public constant DRAGONSWAP_ROUTER = 0xa4cF2F53D1195aDDdE9e4D3aCa54f556895712f2; // Sei
  address public constant DRAGONSWAP_FACTORY = 0x71f6b49ae1558357bBb5A6074f1143c46cBcA03d; // Sei

  function setUp() public virtual override {
    chain = ForkChain.SEI;
    super.setUp();
  }

  function deployUniswapV2Swapper(address ghostBook) public {
    swapper = new UniswapV2SwapperWrapper(ghostBook);
  }

  // Helper to calculate a price tick from pool reserves
  function _calculateTickFromReserves(uint256 reserveIn, uint256 reserveOut) internal pure returns (Tick) {
    // For Uniswap V2 style pools, price is reserveOut/reserveIn
    return TickLib.tickFromVolumes(reserveIn, reserveOut);
  }
}
