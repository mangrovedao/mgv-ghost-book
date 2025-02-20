// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleDeployer, console} from "./ModuleDeployer.s.sol";
import {UniswapV3Swapper} from "../../src/modules/UniswapV3Swapper.sol";

contract UniswapV3ModuleDeployer is ModuleDeployer {
  function deployModule() public override returns (address module) {
    vm.broadcast();
    module = address(new UniswapV3Swapper(address(mangroveGhostBook)));

    console.log("UniswapV3Swapper deployed at:", module);
  }
}
