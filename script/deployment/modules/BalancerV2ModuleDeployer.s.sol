// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ModuleDeployer, console} from "./ModuleDeployer.s.sol";
import {BalancerV2Swapper} from "src/modules/BalancerV2Swapper.sol";

contract BalancerV2ModuleDeployer is ModuleDeployer {
  function deployModule() public override returns (address module) {
    vm.broadcast();
    module = address(new BalancerV2Swapper(address(mangroveGhostBook)));

    console.log("BalancerV2Swapper deployed at:", module);
  }
}
