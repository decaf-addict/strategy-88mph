from brownie import Contract, Wei
from eth_abi import encode_abi
import pytest


def yswap_execute(tradeFactory, strategy, tokenIn, tokenOut, swapper, mech):
    print(f"Executing trades...")
    for id in tradeFactory.pendingTradesIds(strategy):
        trade = tradeFactory.pendingTradesById(id).dict()
        token_in = trade["_tokenIn"]
        token_out = trade["_tokenOut"]
        print(f"Executing trade {id}, tokenIn: {token_in} -> tokenOut {token_out}")

        # most liquid path
        usdc = "0x04068da6c83afcfa0e13ba15a6696662335d5b75"
        path = [tokenIn, usdc, tokenOut]
        if token_out == usdc:
            path = [tokenIn, tokenOut]
        trade_data = encode_abi(["address[]"], [path])
        tradeFactory.execute["uint256, address, uint, bytes"](
            id, swapper.address, 1e6, trade_data, {"from": mech}
        )


def airdrop_want(whale, want, strategy, amount):
    want.approve(strategy, amount, {"from": whale})
    want.transfer(strategy, amount, {"from": whale})
