import pytest
import brownie
import test_operation


def test_clone(Strategy, strategy, vault, vault2, pool, pool2, tradeFactory, strategist, rewards, keeper,
               chain, gov, amount2, min2, strategyFactory, mech, swapper, token_whale, percentageFeeModel, percentageFeeModelOwner,
               accounts, token, token2, user, amount, RELATIVE_APPROX):
    with brownie.reverts("Strategy already initialized"):
        strategy.initialize(vault, strategist, rewards, keeper, pool, tradeFactory, "", {'from': gov})

    transaction = strategyFactory.clone(vault2, strategist, rewards, keeper, pool2, tradeFactory, "new strategy name",
                                        {'from': gov})
    cloned_strategy = Strategy.at(transaction.return_value)

    cloned_strategy.setMinWithdraw(min2[0], {'from': gov})

    with brownie.reverts("Strategy already initialized"):
        cloned_strategy.initialize(vault, strategist, rewards, keeper, pool2, tradeFactory, "",
                                   {'from': gov})

    vault2.addStrategy(cloned_strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})

    # test operations with clone strategy
    test_operation.test_profitable_harvest(chain, accounts, token, vault, strategy, user, strategist, amount, mech,
                                           swapper, RELATIVE_APPROX, gov,
                                           tradeFactory, token_whale, percentageFeeModel, percentageFeeModelOwner)
