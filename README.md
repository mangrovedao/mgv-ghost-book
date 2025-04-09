# Mangrove GhostBook

## Overview

Mangrove GhostBook is a specialized protocol component that enhances the Mangrove DEX ecosystem by enabling cross-venue liquidity routing with price protection. It creates a bridge between Mangrove's native limit order book and external AMM venues like Uniswap, SplitStream, and Aerodrome, allowing traders to access the best liquidity while maintaining strong price guarantees.

## Key Features

- **Cross-Venue Liquidity**: Execute orders across multiple liquidity sources in a single atomic transaction
- **Price Protection**: Enforce maximum price (tick) limits across all execution venues
- **Extensible Architecture**: Modular design with swappable liquidity source adapters
- **MEV Protection**: Atomic execution with slippage controls prevents sandwich attacks
- **Gas Optimization**: Smart routing minimizes gas costs across complex execution paths

## Architecture

### Core Components

1. **MangroveGhostBook.sol**
   - Central contract that orchestrates order execution across venues
   - Enforces price limits and manages whitelisted modules
   - Handles token transfers, approvals, and user interactions

2. **External Swap Modules**
   - **UniswapV3Swapper.sol**: Integration with Uniswap V3 pools
   - **SplitStreamSwapper.sol**: Integration with SplitStream DEX
   - **AerodromeSwapper.sol**: Integration with Aerodrome/Velodrome

### Technical Design

GhostBook follows a modular, extensible architecture:

```
User → MangroveGhostBook → [External DEX Module] → External Liquidity
                        → [Mangrove] → Mangrove Orderbook
```

1. **Order Flow**:
   - Users specify a trading pair, amount, and maximum price (tick)
   - GhostBook attempts to execute on external venue first
   - Any unfilled amount cascades to Mangrove's order book
   - All execution respects the user's maximum price limit

2. **Module System**:
   - Each external venue is integrated via a dedicated swap module
   - Modules must be whitelisted by GhostBook governance
   - Common interface allows adding new venues with minimal changes

3. **Price Representation**:
   - Uses Mangrove's tick system for consistent price representation
   - Converts between different DEX price formats (ticks, sqrt price, etc.)
   - Enforces price limits across all execution paths

## Contract Interfaces

### MangroveGhostBook

```solidity
// Main trade execution function
function marketOrderByTick(
    OLKey memory olKey,
    Tick maxTick,
    uint256 amountToSell,
    ModuleData calldata moduleData
) external returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid);

// External swap execution (called internally)
function externalSwap(
    OLKey memory olKey,
    uint256 amountToSell,
    Tick maxTick,
    ModuleData calldata moduleData,
    address taker
) public returns (uint256 gave, uint256 got);

// Module management
function whitelistModule(address _module) external onlyOwner;
function blacklistModule(address _module) external onlyOwner;
```

### External Swap Module Interface

```solidity
interface IExternalSwapModule {
    function externalSwap(
        OLKey memory olKey,
        uint256 amountToSell,
        Tick maxTick,
        bytes memory data
    ) external;
}
```

## Usage Examples

### Basic Market Order

```solidity
// Create OLKey for WETH/USDC pair
OLKey memory olKey = OLKey({
    outbound_tkn: USDC_ADDRESS,
    inbound_tkn: WETH_ADDRESS,
    tickSpacing: 1
});

// Set maximum price as a tick
Tick maxTick = Tick.wrap(1000);  // Price limit 

// Set amount to sell (e.g., 1 WETH)
uint256 amountToSell = 1 ether;

// Create module data for SplitStream
ModuleData memory moduleData = ModuleData({
    module: IExternalSwapModule(SPLITSTREAM_SWAPPER_ADDRESS),
    data: abi.encode(
        SPLITSTREAM_ROUTER,
        uint24(1),                // tickSpacing
        block.timestamp + 3600,   // deadline
        uint24(1)                 // tickSpacing
    )
});

// Execute the market order
(uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid) = 
    ghostBook.marketOrderByTick(olKey, maxTick, amountToSell, moduleData);
```

### Using Aerodrome

```solidity
// For Aerodrome, the module data is different
ModuleData memory moduleData = ModuleData({
    module: IExternalSwapModule(AERODROME_SWAPPER_ADDRESS),
    data: abi.encode(
        false,                    // isStablePool
        AERODROME_FACTORY,
        block.timestamp + 3600    // deadline
    )
});
```

### Using UniswapV3

```solidity
// For Uniswap V3, specify a fee tier
ModuleData memory moduleData = ModuleData({
    module: IExternalSwapModule(UNISWAP_SWAPPER_ADDRESS),
    data: abi.encode(
        UNISWAP_ROUTER, 
        uint24(500)              // 0.05% fee tier
    )
});
```

## Security Considerations

- **Module Whitelisting**: Only whitelisted modules can be used for external swaps
- **Price Limits**: Maximum price (tick) is enforced across all execution venues
- **Reentrancy Protection**: Uses OpenZeppelin's ReentrancyGuard
- **Ownership Control**: Admin functions are protected by Ownable pattern
- **Emergency Recovery**: Includes fund rescue functionality for stuck tokens

## Development and Contribution

### Prerequisites
- Foundry/Forge for contract development and testing
- Node.js and npm/yarn for scripting and deployment

### Testing
```bash
forge test
```

### Deployment
```bash
forge script script/MangroveGhostBookDeployer.s.sol:MangroveGhostBookDeployer --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.