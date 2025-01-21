// SPDX-License-Identifier: MIT
import {BaseTest, console} from "./BaseTest.t.sol";
import {IMangrove, OLKey, Local} from "@mgv/src/IMangrove.sol";
import {Mangrove} from "@mgv/src/core/Mangrove.sol";
//import {ERC20Mock} from "../helpers/mock/ERC20Mock.sol";
import {MgvReader, Market} from "@mgv/src/periphery/MgvReader.sol";
import {MgvOracle} from "@mgv/src/periphery/MgvOracle.sol";
import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {TestMaker} from "../actors/TestMaker.sol";

contract BaseMangroveTest is BaseTest {
  IMangrove public mgv;
  MgvReader public reader;
  MgvOracle public oracle;

  IMangrove public realMangrove = IMangrove(payable(0x109d9CDFA4aC534354873EF634EF63C235F93f61));
  MgvReader public realReader = MgvReader(0x7E108d7C9CADb03E026075Bf242aC2353d0D1875);

  struct Users {
    TestMaker maker1;
    TestMaker maker2;
    address taker1;
    address taker2;
    address owner;
    address feeRecipient;
    address user;
    address manager;
  }

  Users public users;
  IERC20[] public tokens;

  function setUp() public virtual override {
    super.setUp();

    // Deploy mangrove instance
    deployMangrove();

    // Create test participants
    users.maker1 = setupMaker();
    users.maker2 = setupMaker();
    users.taker1 = makeAddr("mgv-taker-1");
    users.taker2 = makeAddr("mgv-taker-2");
    users.owner = makeAddr("owner");
    users.feeRecipient = makeAddr("feeRecipient");
    users.user = makeAddr("user");
    users.manager = makeAddr("manager");

    // Set tokens
    tokens.push(WETH);
    tokens.push(USDC);
    tokens.push(USDT);
    tokens.push(WeETH);
    tokens.push(ARB);

    // Deal tokens
    dealTokens(address(users.maker1), tokens, 10_000);
    dealTokens(address(users.maker2), tokens, 10_000);
    dealTokens(users.taker1, tokens, 10_000);
    dealTokens(users.taker2, tokens, 10_000);

    // Deal eth to maker contracts
    deal(address(users.maker1), 10 ether);
    deal(address(users.maker2), 10 ether);

    // Approve tokens
    approveTokens(address(users.maker1), address(mgv), tokens, type(uint256).max);
    approveTokens(address(users.maker2), address(mgv), tokens, type(uint256).max);
    approveTokens(users.taker1, address(mgv), tokens, type(uint256).max);
    approveTokens(users.taker2, address(mgv), tokens, type(uint256).max);
  }

  function deployMangrove() internal {
    oracle = new MgvOracle({governance_: address(this), initialMutator_: address(this), initialGasPrice_: 1});
    mgv = IMangrove(payable(address(new Mangrove({governance: address(this), gasprice: 1, gasmax: 2_000_000}))));
    reader = new MgvReader({mgv: address(mgv)});
  }

  function setupMarket(OLKey memory _ol) internal {
    setupMarket(mgv, _ol);
  }

  function setupMaker() public returns (TestMaker) {
    TestMaker tm = new TestMaker(mgv);
    return tm;
  }

  function setupMarket(IMangrove _mgv, OLKey memory _ol) internal {
    _mgv.activate(_ol, 1, 2 ** 32, 40);
  }
}
