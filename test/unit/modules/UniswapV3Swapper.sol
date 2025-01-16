// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseTest, console} from "../../base/BaseTest.t.sol";
import {UniswapV3SwapperWrapper, UniswapV3Swapper} from "../../helpers/mock/UniswapV3SwapperWrapper.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";

contract UniswapV3SwapperTest is BaseTest {
  UniswapV3SwapperWrapper public swapper;
  address public constant UNISWAP_V3_FACTORY_ARBITRUM = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
  address public constant UNISWAP_V3_ROUTER_ARBITRUM = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

  function setUp() public override {
    super.setUp();
    swapper = new UniswapV3SwapperWrapper();
  }

  function test_UniswapV3Swapper_setRouterForFactory() public {
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;
    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);
    swapper.setRouterForFactory(factory, router);
    assertEq(swapper.spenderFor(pool), router);
  }

  function test_UniswapV3Swapper_revert_factory_already_set() public {
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;
    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);
    swapper.setRouterForFactory(factory, router);
    vm.expectRevert(UniswapV3Swapper.RouterAlreadySet.selector);
    swapper.setRouterForFactory(factory, router);
  }

  function test_UniswapV3Swapper_swap_external_limit_price(uint256 mgvTickDepeg) public {
    mgvTickDepeg = bound(mgvTickDepeg, 0, 30);
    uint256 amountToSell = 100 ether;
    address factory = UNISWAP_V3_FACTORY_ARBITRUM;
    address router = UNISWAP_V3_ROUTER_ARBITRUM;

    swapper.setRouterForFactory(factory, router);

    deal(address(WETH), address(swapper), amountToSell);
    swapper.approve(WETH, UNISWAP_V3_ROUTER_ARBITRUM, amountToSell);
    OLKey memory key = OLKey({
      outbound_tkn: address(USDC),
      inbound_tkn: address(WETH),
      tickSpacing: 0 // irrelevant for the test
    });
    address pool = IUniswapV3Factory(factory).getPool(address(WETH), address(USDC), 500);

    (, int24 spotTick,,,,,) = IUniswapV3Pool(pool).slot0();

    Tick maxTick = Tick.wrap(int256(spotTick - int24(uint24(mgvTickDepeg)))); // negative change since its not zero for one

    swapper.externalSwap(key, amountToSell, maxTick, pool, "");
    uint256 tokenInBalanceAfter = WETH.balanceOf(address(swapper));
    uint256 tokenOutBalanceAfter = USDC.balanceOf(address(swapper));
    assertNotEq(tokenOutBalanceAfter, 0);
    if (mgvTickDepeg <= 15) {
      assertNotEq(tokenInBalanceAfter, 0); // didn't swap it all because it reached limit price
    } else {
      assertEq(tokenInBalanceAfter, 0); // it was able to swap it all before reaching Mangrove spot price
    }
  }
}
