import pytest
from brownie import config
from brownie import Contract


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def token():
    token_address = "0xdac17f958d2ee523a2206206994597c13d831ec7"  # USDT
    # token_address = "0x6b175474e89094c44da98b954eedeac495271d0f"  # DAI
    yield Contract(token_address)


@pytest.fixture
def token_whale(accounts):
    yield accounts.at("0xa929022c9107643515f5c777ce9a910f0d1e490c", force=True)


@pytest.fixture
def amount(accounts, token, user, token_whale):
    amount = 10_000 * 10 ** token.decimals()

    token.transfer(user, amount, {"from": token_whale})
    yield amount


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
def integrator():
    integrator = "0xb1b225402b5ec977af8c721f42f21db5518785dc"  # USDT via Aave
    yield integrator


@pytest.fixture
def stakeToken():
    yield Contract("0x1702F18c1173b791900F81EbaE59B908Da8F689b")


@pytest.fixture
def bancorRegistry():
    yield Contract("0x52Ae12ABe5D8BD778BD5397F99cA900624CfADD4")


@pytest.fixture
def nftDescriptor():
    yield Contract("0x99dc678f49c7e6ba60932c2814ce13c225d8caa7")


@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, integrator, stakeToken, bancorRegistry, nftDescriptor):
    strategy = strategist.deploy(Strategy, vault, integrator, stakeToken, bancorRegistry, nftDescriptor)
    strategy.setKeeper(keeper)
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
