// SPDX-License-Identifier: MIT
import {UniswapV3Swapper} from "src/modules/UniswapV3Swapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

contract UniswapV3SwapperWrapper is UniswapV3Swapper {
  function approve(IERC20 token, address spender, uint256 amount) public {
    token.approve(spender, amount);
  }
}
