// SPDX-License-Identifier: MIT
import {BaseTest, console} from "../BaseTest.t.sol";
import {UniswapV3SwapperWrapper} from "../../helpers/mock/UniswapV3SwapperWrapper.sol";

abstract contract BaseUniswapV3SwapperTest is BaseTest {
  UniswapV3SwapperWrapper public swapper;
  address public constant UNISWAP_V3_FACTORY_ARBITRUM = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
  address public constant UNISWAP_V3_ROUTER_ARBITRUM = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

  /// @dev Helper function to convert from Uniswap tick to Mangrove tick as prices are represented differently
  function _convertToMgvTick(address inboundToken, address outboundToken, int24 uniswapTick)
    internal
    pure
    returns (int24)
  {
    // Compare addresses to determine token ordering without storage reads
    // If inbound token has lower address, it's token0 in Uniswap
    if (uniswapTick < 0) return -(uniswapTick);
    return uniswapTick;
  }

  function deployUniswapV3Swapper(address ghostBook) internal returns (UniswapV3SwapperWrapper) {
    swapper = new UniswapV3SwapperWrapper(ghostBook);
    return swapper;
  }
}
