from brownie import Strategy, StrategyFactory, accounts, config, network, project, web3


def main():
    with open('./build/contracts/StrategyFlat.sol', 'w') as f:
        Strategy.get_verification_info()
        f.write(Strategy._flattener.flattened_source)
    with open('./build/contracts/StrategyFactoryFlat.sol', 'w') as f:
        StrategyFactory.get_verification_info()
        f.write(StrategyFactory._flattener.flattened_source)