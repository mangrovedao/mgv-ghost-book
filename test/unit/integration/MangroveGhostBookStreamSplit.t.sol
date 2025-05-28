import {BaseMangroveTest, BaseTest, console} from "../../base/BaseMangroveTest.t.sol";
import {BaseSplitStreamSwapperTest} from "../../base/modules/BaseSplitStreamSwapperTest.t.sol";
import {SplitStreamSwapper} from "src/modules/SplitStreamSwapper.sol";
import {MangroveGhostBook, ModuleData} from "src/MangroveGhostBook.sol";
import {IExternalSwapModule} from "src/interface/IExternalSwapModule.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";

interface ISplitStreamFactory {
  function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}

interface ISplitStreamPool {
  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      bool unlocked
    );
}

contract MangroveGhostBookStreamSplitTest is BaseMangroveTest, BaseSplitStreamSwapperTest {
  MangroveGhostBook public ghostBook;
  OLKey public ol;

  bool constant IS_STABLE_POOL = false;

  int24 constant TICK_SPACING = 1; // Common tick spacing, adjust for SplitStream

  function setUp() public override(BaseMangroveTest, BaseSplitStreamSwapperTest) {
    chain = ForkChain.BASE;
    super.setUp();
    setUpLabels();
    ol = OLKey({outbound_tkn: address(USDC), inbound_tkn: address(USDT), tickSpacing: uint24(TICK_SPACING)});

    ghostBook = new MangroveGhostBook(address(mgv));
    deploySplitStreamSwapper(address(ghostBook));
    ghostBook.whitelistModule(address(swapper));

    // Approve tokens
    approveTokens(users.taker1, address(ghostBook), tokens, type(uint256).max);
    approveTokens(users.taker2, address(ghostBook), tokens, type(uint256).max);

    // Set up makers
    users.maker1.setKey(ol);
    users.maker1.provisionMgv(1 ether);
    users.maker2.setKey(ol);
    users.maker2.provisionMgv(1 ether);
  }

  function setUpLabels() internal {
    vm.label(address(WETH), "WETH");
    vm.label(address(USDC), "USDC");
    vm.label(address(USDT), "USDT");
  }

  function test_GhostBook_only_stream_execution() public {
    uint256 amountToSell = 0.1 ether;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(SPLITSTREAM_ROUTER, uint24(TICK_SPACING), block.timestamp + 3600, uint24(TICK_SPACING))
    });

    setupMarket(ol);
    Tick mgvTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, 1000)));
    users.maker1.newOfferByTick(mgvTick, 5_000e6, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) =
      ghostBook.marketOrderByTick(ol, mgvTick, amountToSell, data);

    assertGt(takerGot, 0);
    assertGt(takerGave, 0);
  }

  function test_GhostBook_price_limit_respected_stream() public {
    uint256 amountToSell = 0.5 ether;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(SPLITSTREAM_ROUTER, uint24(TICK_SPACING), block.timestamp + 3600, uint24(TICK_SPACING))
    });

    setupMarket(ol);
    address pool = ISplitStreamFactory(SPLITSTREAM_FACTORY).getPool(ol.inbound_tkn, ol.outbound_tkn, TICK_SPACING);
    (, int24 spotTick,,,,) = ISplitStreamPool(pool).slot0();
    Tick maxTick = Tick.wrap(Tick.unwrap(Tick.wrap(int256(spotTick))) + 2000);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    assertLe(takerGave, amountToSell);
    if (takerGot > 0 && takerGave > 0) {
      Tick executedTick = TickLib.tickFromVolumes(takerGave, takerGot);
      assertLe(Tick.unwrap(executedTick), Tick.unwrap(maxTick));
    }
  }

  function test_GhostBook_combined_liquidity_stream() public {
    uint256 amountToSell = 1 ether;
    ModuleData memory data = ModuleData({
      module: IExternalSwapModule(address(swapper)),
      data: abi.encode(SPLITSTREAM_ROUTER, uint24(TICK_SPACING), block.timestamp + 3600, uint24(TICK_SPACING))
    });

    setupMarket(ol);
    address pool = ISplitStreamFactory(SPLITSTREAM_FACTORY).getPool(ol.inbound_tkn, ol.outbound_tkn, TICK_SPACING);
    (, int24 spotTick,,,,) = ISplitStreamPool(pool).slot0();
    Tick betterTick = Tick.wrap(int256(_convertToMgvTick(ol.inbound_tkn, ol.outbound_tkn, spotTick + 200)));
    Tick maxTick = Tick.wrap(Tick.unwrap(betterTick) + 200);

    users.maker1.newOfferByTick(betterTick, 10_000 ether, 2 ** 18);

    vm.startPrank(users.taker1);
    (uint256 takerGot, uint256 takerGave,,) = ghostBook.marketOrderByTick(ol, maxTick, amountToSell, data);

    assertEq(takerGave, amountToSell);
    assertGt(takerGot, 0);
  }
}
