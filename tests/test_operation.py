import brownie
from brownie import Contract
import pytest


def test_operation(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, percentageFeeModel,
        percentageFeeModelOwner
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})

    # tend()
    strategy.tend()

    chain.sleep(7 * 24 * 60 * 60)
    chain.mine(1)

    # withdrawal
    vault.withdraw({"from": user})
    assert (pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == user_balance_before)


def test_emergency_exit(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, percentageFeeModel,
        percentageFeeModelOwner
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})
    # set emergency and exit
    strategy.setEmergencyExit()
    chain.sleep(1)
    strategy.harvest()
    assert strategy.estimatedTotalAssets() < amount


def test_profitable_harvest(
        chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov
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
    chain.sleep(3600 * 24 * 50)
    strategy.tend({"from": gov})

    before_pps = vault.pricePerShare()

    # Harvest 2: Realize profit
    chain.sleep(1)
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

    # turn off selling of rewards so that we isolate gains from collecting fixed-interest
    strategy.setStakePercentage(10000, {'from': gov})
    strategy.setUnstakePercentage(0, {'from': gov})

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # half a year to mature deposit
    chain.sleep(181 * 24 * 60 * 60)
    chain.mine(1)

    old_deposit_id = strategy.depositId()
    old_vest_id = strategy.vestId()

    assert strategy.hasMatured() == True

    before_pps = vault.pricePerShare()
    # tend rolls over current to new deposit to continue new vest
    strategy.tend()

    # harvest collects the interest
    strategy.harvest()
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
        percentageFeeModel, percentageFeeModelOwner
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()
    half = int(amount / 2)
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == half

    chain.sleep(6 * 3600)
    strategy.harvest()

    # remove .5% early withdrawal fee
    percentageFeeModel.overrideEarlyWithdrawFeeForDeposit(strategy.pool(), strategy.depositId(), 0,
                                                          {'from': percentageFeeModelOwner})
    pps_1 = vault.pricePerShare()

    vault.updateStrategyDebtRatio(strategy.address, 10_000, {"from": gov})
    chain.sleep(3600)
    strategy.harvest()
    chain.sleep(6 * 3600)
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= amount

    pps_2 = vault.pricePerShare()
    assert pps_2 > pps_1

    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(3600)
    strategy.harvest()
    chain.sleep(6 * 3600)
    chain.mine(1)
    assert strategy.estimatedTotalAssets() >= half

    pps_3 = vault.pricePerShare()
    assert pps_3 > pps_2

    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(3600)
    strategy.harvest()
    chain.sleep(6 * 3600)
    chain.mine(1)
    # rounding error + 5
    assert strategy.estimatedTotalAssets() <= strategy.dust() + 5

    pps_4 = vault.pricePerShare()
    assert pps_4 > pps_3


def test_sweep(gov, vault, strategy, token, user, amount, weth, weth_amout):
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
        chain, gov, vault, strategy, token, amount, user, weth, weth_amout, strategist
):
    # Deposit to the vault and harvest
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    vault.updateStrategyDebtRatio(strategy.address, 5_000, {"from": gov})
    chain.sleep(1)
    strategy.harvest()

    strategy.harvestTrigger(0)
    strategy.tendTrigger(0)
