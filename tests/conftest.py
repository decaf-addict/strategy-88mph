import pytest
from brownie import config
from brownie import Contract


# Function scoped isolation fixture to enable xdist.
# Snapshots the chain before each test and reverts after test completion.
@pytest.fixture(scope="function", autouse=True)
def shared_setup(fn_isolation):
    pass


@pytest.fixture(scope="session")
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture(scope="session")
def user(accounts):
    yield accounts[0]


@pytest.fixture(scope="session")
def rewards(accounts):
    yield accounts[1]


@pytest.fixture(scope="session")
def guardian(accounts):
    yield accounts[2]


@pytest.fixture(scope="session")
def management(accounts):
    yield accounts[3]


@pytest.fixture(scope="session")
def strategist(accounts):
    yield accounts[4]


@pytest.fixture(scope="session")
def keeper(accounts):
    yield accounts[5]


token_address = {
    "GUSD": "0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd",
    "USDT": "0xdac17f958d2ee523a2206206994597c13d831ec7",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
    "DAI": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "USDC": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
}


@pytest.fixture(params=[
    # "GUSD", # Bancor has no GUSD liquidity rip...
    "USDT",
    "WETH",
    "WBTC",
    "DAI",
    "USDC",
    "LINK",
],
    scope="session",
    autouse=True)
def token(request):
    yield Contract(token_address[request.param])


whale_address = {
    "GUSD": "0x5f65f7b609678448494De4C87521CdF6cEf1e932",
    "USDT": "0xa929022c9107643515f5c777ce9a910f0d1e490c",
    "WETH": "0x030ba81f1c18d280636f32af80b9aad02cf0854e",
    "WBTC": "0xccf4429db6322d5c611ee964527d42e5d685dd6a",
    "DAI": "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",
    "USDC": "0x0A59649758aa4d66E25f08Dd01271e891fe52199",
    "LINK": "0x98C63b7B319dFBDF3d811530F2ab9DfE4983Af9D",
}


@pytest.fixture(scope="session", autouse=True)
def token_whale(accounts, token):
    yield accounts.at(whale_address[token.symbol()], force=True)


pools = {
    "GUSD": "0xbFDB51ec0ADc6D5bF2ebBA54248D40f81796E12B",  # GUSD via Aave
    "USDT": "0xb1b225402b5ec977af8c721f42f21db5518785dc",  # USDT via Aave
    "WETH": "0xaE5ddE7EA5c44b38c0bCcfb985c40006ED744EA6",  # WETH via Aave
    "WBTC": "0xA0E78812E9cD3E754a83bbd74A3F1579b50436E8",  # WBTC via Compound
    # "DAI": "0x4B4626c1265d22B71ded11920795A3c6127A0559",  # DAI via BProtocol
    "DAI": "0x6D97eA6e14D35e10b50df9475e9EFaAd1982065E",  # DAI via Aave
    "USDC": "0xF61681b8Cbf87615F30f96F491FA28a2Ff39947a",  # USDC via Cream
    "LINK": "0x572be575d1aa1ca84d8ac4274067f7bcb578a368",  # LINK via Compound
}


@pytest.fixture(scope="session", autouse=True)
def pool(token):
    yield pools[token.symbol()]


amounts = {
    "GUSD": 10_000_000,  # GUSD via Aave
    "USDT": 10_000_000,  # USDT via Aave
    "WETH": 10_000,  # WETH via Aave
    "WBTC": 1_000,  # WBTC via Compound
    "DAI": 10_000_000,  # DAI via BProtocol/Aave
    "USDC": 10_000_000,  # USDC via Cream
    "LINK": 500_000,  # LINK via Compound
}


@pytest.fixture(scope="function", autouse=True)
def amount(accounts, token, user, token_whale):
    amount = amounts[token.symbol()] * 10 ** token.decimals()
    token.transfer(user, amount, {"from": token_whale})
    yield amount


token2_address = {
    "GUSD": "0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd",
    "USDT": "0xdac17f958d2ee523a2206206994597c13d831ec7",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    "WBTC": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
    "DAI": "0x6b175474e89094c44da98b954eedeac495271d0f",
    "USDC": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
}

# map for testing clones. I.e. Original: GUSD -> Cloned: USDT
token_to_token2 = {
    "GUSD": "USDT",
    "USDT": "WETH",
    "WETH": "WBTC",
    "WBTC": "DAI",
    "DAI": "USDC",
    "USDC": "LINK",
    "LINK": "GUSD",
}


@pytest.fixture(scope="session", autouse=True)
def token2(token):
    yield Contract(token2_address[token_to_token2[token.symbol()]])


@pytest.fixture(scope="session", autouse=True)
def token2_whale(accounts, token2):
    yield accounts.at(whale_address[token2.symbol()], force=True)


@pytest.fixture(scope="session", autouse=True)
def pool2(token2):
    yield pools[token2.symbol()]


@pytest.fixture(scope="function", autouse=True)
def amount2(accounts, token2, user, token2_whale):
    amount = amounts[token2.symbol()] * 10 ** token2.decimals()
    token2.transfer(user, amount, {"from": token2_whale})
    yield amount


# some protocols like compound have a minimum withdrawal amount due to difference in decimals (cDAI is 8 decimals)
# 1e10 comes from DAI dec 1e18 - cDAI decimal 1e8 -> need a minimum of 1e10 DAI in order to swap out cDAI > 0
mins = {
    "GUSD": [0, 0],  # GUSD via Aave
    "USDT": [0, 0],  # USDT via Aave
    "WETH": [0, 0],  # WETH via Aave
    "WBTC": [0, 1e1],  # WBTC via Compound
    # "DAI": [1e10, 1e9],  # DAI via BProtocol
    "DAI": [0, 0],  # DAI via Aave
    "USDC": [0, 1e2],  # USDC via Cream
    "LINK": [1e10, 1e6],  # LINK via Compound
}


@pytest.fixture(scope="session", autouse=True)
def min(token):
    yield mins[token.symbol()]


@pytest.fixture(scope="session", autouse=True)
def min2(token2):
    yield mins[token2.symbol()]


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)


@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout


@pytest.fixture
def stakeToken():
    yield Contract("0x1702F18c1173b791900F81EbaE59B908Da8F689b")


@pytest.fixture
def bancorRegistry():
    yield Contract("0x52Ae12ABe5D8BD778BD5397F99cA900624CfADD4")


@pytest.fixture(scope="function", autouse=True)
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture(scope="function", autouse=True)
def vault2(pm, gov, rewards, guardian, management, token2):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token2, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture
def percentageFeeModelOwner(accounts):
    yield accounts.at("0x56f34826cc63151f74fa8f701e4f73c5eaae52ad", force=True)


@pytest.fixture
def percentageFeeModel():
    yield Contract("0x9c2ae492ec3A49c769bABffC9500256749404f8E")


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, pool, stakeToken, bancorRegistry, min):
    strategy = strategist.deploy(Strategy, vault, pool, stakeToken, bancorRegistry)
    strategy.setKeeper(keeper)
    strategy.setMinWithdraw(min[0], {'from': gov})
    strategy.setDust(min[1], {'from': gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
