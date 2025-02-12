# Mangrove Ghostbook

Mangrove ghost book is a tool to enable consuming liquidity outside of mangrove at a better price than the best offer on Mangrove.

## How it works

The main ghostbook contract is first fetching the best offer on mangrove and then consumes the liquidity outside of mangrove using modules.

The module is a bit of code that is called and given the tokens and then called. At the end of the execution the module is expected to have the tokens received as well as the non used toens.

The price of this external trade is then inferred and enforced to be smaller than the best offer on mangrove.

Modules can be deployed by anyone but are to be whitelisted by the ghostbook before use.

## Modules

### Uniswap V3 module

The uniswap V3 module receives the router address and the fee of the pool to be used, then from the current market it takes the given pool and performs a swap with aexact input and limit price.
