import pytest
import brownie
import test_operation


def test_clone(Strategy, strategy, vault, vault2, pool, pool2, stakeToken, tradeFactory, strategist, rewards, keeper,
               chain, gov, amount2, min2,
               accounts, token, token2, user, amount, RELATIVE_APPROX):
    with brownie.reverts("Strategy already initialized"):
        strategy.initialize(vault, strategist, rewards, keeper, pool, stakeToken, tradeFactory)

    transaction = strategy.clone(vault2, strategist, rewards, keeper, pool2, stakeToken, tradeFactory)
    cloned_strategy = Strategy.at(transaction.return_value)

    cloned_strategy.setMinWithdraw(min2[0], {'from': gov})
    cloned_strategy.setDust(min2[1], {'from': gov})

    with brownie.reverts("Strategy already initialized"):
        cloned_strategy.initialize(vault, strategist, rewards, keeper, pool2, stakeToken, tradeFactory, {'from': gov})

    vault2.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    # test operations with clone strategy
    test_operation.test_profitable_harvest(chain, accounts, token2, vault2, cloned_strategy, user, strategist, amount2,
                                           RELATIVE_APPROX, gov)
