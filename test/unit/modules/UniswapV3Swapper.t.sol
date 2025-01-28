// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseUniswapV3SwapperTest, console} from "../../base/modules/BaseUniswapV3SwapperTest.t.sol";
import {UniswapV3SwapperWrapper, UniswapV3Swapper} from "../../helpers/mock/UniswapV3SwapperWrapper.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {SafeERC20, IERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import "forge-std/src/Test.sol";

contract UniswapV3SwapperTest is BaseUniswapV3SwapperTest {
  address ghostBook = makeAddr("mgv-ghostbook");

  function setUp() public override {
    super.setUp();
    deployUniswapV3Swapper(ghostBook);
    deal(address(WETH), ghostBook, 10_000 ether);
    vm.startPrank(ghostBook);
  }

  function testFuzz_UniswapV3Swapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    mgvTickDepeg = bound(mgvTickDepeg, 0, 30);
    uint256 amountToSell = 100 ether;
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;

    deal(address(WETH), address(swapper), amountToSell);
    OLKey memory ol = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });
    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);

    (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();

    Tick maxTick =
      Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick - int24(uint24(mgvTickDepeg))))); // negative change since its not zero for one

    uint256 tokenInBalanceBefore = WETH.balanceOf(address(ghostBook));
    uint256 tokenOutBalanceBefore = USDC.balanceOf(address(ghostBook));

    swapper.externalSwap(ol, amountToSell, maxTick, abi.encode(router, uint24(500)));

    uint256 tokenInBalanceAfter = WETH.balanceOf(address(ghostBook));
    uint256 tokenOutBalanceAfter = USDC.balanceOf(address(ghostBook));

    assertNotEq(tokenOutBalanceAfter - tokenOutBalanceBefore, 0);

    if (mgvTickDepeg <= 15) {
      assertNotEq(tokenInBalanceAfter - tokenInBalanceBefore, 0); // didn't swap it all because it reached limit price
    } else {
      assertEq(tokenInBalanceAfter - tokenInBalanceBefore, 0); // it was able to swap it all before reaching Mangrove spot price
    }
  }
}
