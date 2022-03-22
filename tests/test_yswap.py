import pytest
from brownie import Contract, chain, accounts
import eth_utils
from eth_abi.packed import encode_abi_packed
import util


# mph to usdt
def test_execute_yswaps(strategy, mph_token, yMechs, gov, user, amount, token, vault, RELATIVE_APPROX, router, yswaps_path, weth):
    if token != weth:

        # Deposit to the vault
        user_balance_before = token.balanceOf(user)
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        assert token.balanceOf(vault.address) == amount

        # harvest
        chain.sleep(1)
        strategy.harvest({"from": gov})
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

        # generate some rewards
        chain.sleep(3600 * 24)
        chain.mine(10)

        strategy.tend({'from': gov})
        assert strategy.balanceOfReward() > 0

        tradeFactory = Contract(strategy.tradeFactory())
        multicall_swapper = Contract("0x711d1D8E8B2b468c92c202127A2BBFEFC14bf105")
        receiver = strategy
        token_out = Contract(strategy.want())

        id = mph_token
        print(id.address)
        token_in = id

        amount_in = id.balanceOf(strategy)
        print(
            f"Executing trade {id}, tokenIn: {token_in.symbol()} -> tokenOut {token_out.symbol()} w/ amount in {amount_in / 1e18}"
        )

        asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]

        # always start with optimisations. 5 is CallOnlyNoValue
        optimsations = [["uint8"], [5]]
        a = optimsations[0]
        b = optimsations[1]

        calldata = token_in.approve.encode_input(router, amount_in)
        t = _create_tx(token_in, calldata)
        a = a + t[0]
        b = b + t[1]

        calldata = router.claimAndConvert.encode_input(
            yswaps_path,
            amount_in,
            1
        )
        t = _create_tx(router, calldata)
        a = a + t[0]
        b = b + t[1]

        expected_out = router.rateByPath(yswaps_path, amount_in)

        calldata = token_out.transfer.encode_input(receiver, expected_out)
        t = _create_tx(token_out, calldata)
        a = a + t[0]
        b = b + t[1]

        transaction = encode_abi_packed(a, b)

        tradeFactory.execute["tuple,address,bytes"](
            asyncTradeExecutionDetails,
            multicall_swapper,
            transaction,
            {'from': yMechs}
        )
        print(f"Strategy {token_out.symbol()} balance: {token_out.balanceOf(strategy) / 10 ** token_out.decimals():.6f}")


def _create_tx(to, data):
    inBytes = eth_utils.to_bytes(hexstr=data)
    return [["address", "uint256", "bytes"], [to.address, len(inBytes), inBytes]]
