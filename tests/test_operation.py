import brownie
from brownie import Contract
import pytest
import util


def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, percentageFeeModel,
        percentageFeeModelOwner, gov
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})

    # tend()
    strategy.tend({"from": gov})

    chain.sleep(7 * 24 * 60 * 60)
    chain.mine(1)

    # withdrawal
    vault.withdraw({"from": user})
    assert (pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before)


def test_emergency_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, percentageFeeModel,
        percentageFeeModelOwner, gov
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})
    # set emergency and exit
    strategy.setEmergencyExit({"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
        chain, accounts, token, vault, strategy, user, strategist, amount, mech, swapper, RELATIVE_APPROX, gov,
        tradeFactory
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # rewards vest over time
    chain.sleep(360)
    strategy.tend({"from": gov})

    before_pps = vault.pricePerShare()

    # Harvest 2: Realize profit
    chain.sleep(1)
    strategy.harvest({"from": gov})
    util.yswap_execute(tradeFactory, strategy, strategy.reward(), strategy.want(), swapper, mech)
    strategy.harvest({"from": gov})
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_matured_harvest(chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # half a year to mature deposit
    chain.sleep(181 * 24 * 60 * 60)
    chain.mine(1)

    old_deposit_id = strategy.depositId()
    old_vest_id = strategy.vestId()

    assert strategy.hasMatured() == True
    before_pps = vault.pricePerShare()
    before_id = strategy.depositId()
    # harvest collects the interest
    strategy.harvest({"from": gov})
    assert strategy.depositId() != before_id
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault

    # assert new nfts were created due to rollover to a new deposit
    assert old_deposit_id != strategy.depositId()
    assert strategy.depositId() != strategy.vestId()
    assert old_vest_id != strategy.vestId()
    assert strategy.estimatedTotalAssets() + profit > amount
    assert vault.pricePerShare() > before_pps


def test_change_debt(
        chain, gov, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX,
        percentageFeeModel, percentageFeeModelOwner, tradeFactory, swapper, mech
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": gov})
    half = amount / 2
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    chain.sleep(6 * 3600)
    strategy.harvest({"from": gov})

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})
    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(3600)
    strategy.harvest({"from": gov})

    chain.sleep(6 * 3600)
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= amount

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(3600)
    strategy.harvest({"from": gov})
    util.yswap_execute(tradeFactory, strategy, strategy.reward(), strategy.want(), swapper, mech)
    strategy.harvest({"from": gov})

    chain.sleep(6 * 3600)
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= half

    before_pps = vault.pricePerShare()
    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(3600)
    strategy.harvest({"from": gov})
    chain.sleep(6 * 3600)
    chain.mine(1)
    # compounding dusts and rounding errors + 5
    assert strategy.estimatedTotalAssets() <= strategy.dust() * 10 + 5

    after_pps = vault.pricePerShare()
    assert after_pps > before_pps


def test_sweep(gov, vault, strategy, token, user, amount, wftm, wftm_amount):
    # Strategy want token doesn't work
    token.transfer(strategy, amount, {"from": user})
    assert token.address == strategy.want()
    assert token.balanceOf(strategy) > 0
    with brownie.reverts("!want"):
        strategy.sweep(token, {"from": gov})

    # Vault share token doesn't work
    with brownie.reverts("!shares"):
        strategy.sweep(vault.address, {"from": gov})

    # TODO: If you add protected tokens to the strategy.
    # Protected token doesn't work
    # with brownie.reverts("!protected"):
    #     strategy.sweep(strategy.protectedToken(), {"from": gov})

    # we have a strat for weth

    # before_balance = weth.balanceOf(gov)
    # weth.transfer(strategy, weth_amout, {"from": user})
    # assert weth.address != strategy.want()
    # assert weth.balanceOf(user) == 0
    # strategy.sweep(weth, {"from": gov})
    # assert weth.balanceOf(gov) == weth_amout + before_balance


def test_triggers(
        chain, gov, vault, strategy, token, amount, user, wftm, wftm_amount, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest({"from": gov})

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
