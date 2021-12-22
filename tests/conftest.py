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
    "WFTM": "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83",
    "DAI": "0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E",
    "USDC": "0x04068DA6C83AFCFA0e13ba15A6696662335D5B75"
}


@pytest.fixture(params=[
    "WFTM",
    "DAI",
    "USDC",
],
    scope="session",
    autouse=True)
def token(request):
    yield Contract(token_address[request.param])


whale_address = {
    "WFTM": "0x39B3bd37208CBaDE74D0fcBDBb12D606295b430a",
    "DAI": "0x07E6332dD090D287d3489245038daF987955DCFB",
    "USDC": "0x2dd7C9371965472E5A5fD28fbE165007c61439E1"
}


@pytest.fixture(scope="session", autouse=True)
def token_whale(accounts, token):
    yield accounts.at(whale_address[token.symbol()], force=True)


pools = {
    "WFTM": "0x23fe5a2BA80ea2251843086eC000911CFc79c864",  # WFTM via Geist
    "DAI": "0xa78276C04D8d807FeB8271fE123C1f94c08A414d",  # DAI via Scream"
    "USDC": "0xF7fb7F095C8D0F4ee8ffBd142FE0b311491B45F3",  # USDC via Scream
}


@pytest.fixture(scope="session", autouse=True)
def pool(token):
    yield pools[token.symbol()]


amounts = {
    "WFTM": 1_000_000,  # WFTM via Geist
    "DAI": 10_000_000,  # DAI via Scream
    "USDC": 10_000_000,  # USDC via Scream
}


@pytest.fixture(scope="function", autouse=True)
def amount(accounts, token, user, token_whale):
    amount = amounts[token.symbol()] * 10 ** token.decimals()
    token.transfer(user, amount, {"from": token_whale})
    yield amount


# map for testing clones. I.e. Original: GUSD -> Cloned: USDT
token_to_token2 = {
    "WFTM": "DAI",
    "DAI": "USDC",
    "USDC": "WFTM",
}


@pytest.fixture(scope="session", autouse=True)
def token2(token):
    yield Contract(token_address[token_to_token2[token.symbol()]])


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
    "WFTM": [0, 0],  # WFTM via Geist
    "DAI": [1e8, 1e8],  # DAI via Scream
    "USDC": [0, 1e2],  # USDC via Scream
}


@pytest.fixture(scope="session", autouse=True)
def min(token):
    yield mins[token.symbol()]


@pytest.fixture(scope="session", autouse=True)
def min2(token2):
    yield mins[token2.symbol()]


@pytest.fixture
def wftm():
    token_address = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
    yield Contract(token_address)


@pytest.fixture
def wftm_whale(accounts):
    yield accounts.at("0x39b3bd37208cbade74d0fcbdbb12d606295b430a", force=True)


@pytest.fixture
def wftm_amount(user, wftm, wftm_whale):
    wftm_amount = 10 ** wftm.decimals()
    wftm.transfer(user, wftm_amount, {'from': wftm_whale})
    yield wftm_amount


@pytest.fixture
def stakeToken():
    yield Contract("0x511a986E427FFa281ACfCf07AAd70d03040DbEc0")


@pytest.fixture
def tradeFactory():
    yield Contract("0x34aA402D943Ea983EBF890bD4B4d71239B6E2C00")


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
    yield accounts.at("0x916e78f904B5e854DB0578646AA182C0AAbED8C8", force=True)


@pytest.fixture
def percentageFeeModel():
    yield Contract("0xD7A7485c53D0a2dB0Df0d23B3fABA1560e4Cdacb")


@pytest.fixture
def strategyFactory(strategist, keeper, vault, StrategyFactory, gov, pool, tradeFactory):
    factory = strategist.deploy(StrategyFactory, vault, pool, tradeFactory,
                                "88MPH <TokenSymbol> via <ProtocolName>")
    yield factory


@pytest.fixture
def yMechs():
    yield Contract("0x9f2A061d6fEF20ad3A656e23fd9C814b75fd5803")


@pytest.fixture
def mech(accounts):
    yield accounts.at("0x0000000031669Ab4083265E0850030fa8dEc8daf", force=True)


@pytest.fixture
def swapper(tradeFactory, yMechs):
    # async spooky
    swapper = Contract("0x8298C9a1760346C474c570881B1F6E56ECA038B7")
    tradeFactory.addSwappers([swapper], {"from": yMechs})
    yield swapper


@pytest.fixture
def strategy(keeper, vault, gov, min, strategyFactory, Strategy, tradeFactory, yMechs):
    strategy = Strategy.at(strategyFactory.original())
    strategy.setKeeper(keeper, {'from': gov})
    strategy.setMinWithdraw(min[0], {'from': gov})
    strategy.setDust(min[1], {'from': gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    tradeFactory.grantRole(tradeFactory.STRATEGY(), strategy, {"from": yMechs, "gas_price": "0 gwei"})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
