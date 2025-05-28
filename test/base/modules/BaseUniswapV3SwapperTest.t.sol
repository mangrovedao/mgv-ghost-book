// SPDX-License-Identifier: MIT
import {BaseTest, console} from "../BaseTest.t.sol";
import {UniswapV3SwapperWrapper} from "../../helpers/mock/UniswapV3SwapperWrapper.sol";

abstract contract BaseUniswapV3SwapperTest is BaseTest {
  UniswapV3SwapperWrapper public swapper;
  address public constant UNISWAP_V3_FACTORY_ARBITRUM = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
  address public constant UNISWAP_V3_ROUTER_ARBITRUM = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

  function setUp() public virtual override {
    chain = ForkChain.ARBITRUM;
    super.setUp();
  }

  function deployUniswapV3Swapper(address ghostBook) internal returns (UniswapV3SwapperWrapper) {
    swapper = new UniswapV3SwapperWrapper(ghostBook);
    return swapper;
  }

  // Helper to convert from Uniswap tick to Mangrove tick
  function _convertToMgvTick(address inbound, address outbound, int24 uniswapTick) internal pure returns (int24) {
    return inbound < outbound ? -uniswapTick : uniswapTick;
  }
}
