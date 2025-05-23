// SPDX-License-Identifier: MIT
import {UniswapV2Swapper} from "src/modules/UniswapV2Swapper.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";

contract UniswapV2SwapperWrapper is UniswapV2Swapper {
  constructor(address gb) UniswapV2Swapper(gb) {}

  function approve(IERC20 token, address spender, uint256 amount) public {
    token.approve(spender, amount);
  }
}
