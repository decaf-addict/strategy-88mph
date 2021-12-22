# TODO: Add tests that show proper migration of the strategy to a newer one
#       Use another copy of the strategy to simulate the migration
#       Show that nothing is lost!

import pytest


def test_migration(
        chain,
        token,
        vault,
        strategy,
        amount,
        Strategy,
        StrategyFactory,
        strategist,
        gov,
        user,
        RELATIVE_APPROX,
        pool,
        tradeFactory,
        min,
        yMechs,
        strategyFactory):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({'from': gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # migrate to a new strategy
    new_factory = strategist.deploy(StrategyFactory, vault, pool, tradeFactory, "88MPH <TokenSymbol> via <ProtocolName>")
    new_strategy = Strategy.at(new_factory.original())
    tradeFactory.grantRole(tradeFactory.STRATEGY(), new_strategy, {"from": yMechs, "gas_price": "0 gwei"})
    new_strategy.setOldStrategy(strategy, {'from': gov})
    new_strategy.setMinWithdraw(min[0], {'from': gov})
    new_strategy.setDust(min[1], {'from': gov})
    oldDepositId = strategy.depositId()
    vault.migrateStrategy(strategy, new_strategy, {"from": gov})

    assert (
            pytest.approx(new_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    )

    # harvest to make sure nft ownerships were transferred correctly. Check no reverts
    assert oldDepositId == new_strategy.depositId()
    new_strategy.harvest({'from': gov})
