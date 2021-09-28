// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Math} from "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/Mph.sol";
import "../interfaces/Bancor.sol";


contract Strategy is BaseStrategy, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    INft public nft;
    IDInterest public integrator;
    IVesting public vestor;
    IStake public stake;
    INftDescriptor public nftDescriptor;
    IBancorRegistry public bancorRegistry;
    bytes32 public routerNetwork;

    uint64 public depositId;
    uint public fixedRateInterest;

    uint public stakePercentage;
    uint public unstakePercentage;
    uint constant basisMax = 10000;
    IERC20 public reward;
    uint64 public maturationPeriod = 365 * 24 * 60 * 60;
    bool internal isOriginal = true;
    uint constant private max = type(uint).max;

    constructor(
        address _vault,
        address _integrator,
        address _stakeToken,
        address _bancorRegistry,
        address _nftDescriptor
    )
    public BaseStrategy(_vault){
        _initializeStrat(_vault, _integrator, _stakeToken, _bancorRegistry, _nftDescriptor);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _integrator,
        address _stakeToken,
        address _bancorRegistry,
        address _nftDescriptor

    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _integrator, _stakeToken, _bancorRegistry, _nftDescriptor);
    }

    function _initializeStrat(
        address _vault,
        address _integrator,
        address _stakeToken,
        address _bancorRegistry,
        address _nftDescriptor

    ) internal {
        integrator = IDInterest(_integrator);
        require(address(want) == integrator.stablecoin(), "Wrong integrator!");
        vestor = IVesting(IMphMinter(integrator.mphMinter()).vesting02());
        reward = IERC20(vestor.token());
        nft = INft(integrator.depositNFT());
        stake = IStake(_stakeToken);
        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        bancorRegistry = IBancorRegistry(_bancorRegistry);
        routerNetwork = bytes32("0x42616e636f724e6574776f726b");
        nftDescriptor = INftDescriptor(nftDescriptor);
        want.safeApprove(address(integrator), max);
    }

    event Cloned(address indexed clone);

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _integrator,
        address _stakeToken,
        address _bancorRegistry,
        address _nftDescriptor
    ) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
        // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _integrator, _stakeToken, _bancorRegistry, _nftDescriptor);
        emit Cloned(newStrategy);
    }


    function name() external view override returns (string memory) {
        return "88-MPH Staker";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return hasMatured() ? getDepositInfo().virtualTokenTotalSupply : getDepositInfo().virtualTokenTotalSupply.sub(fixedRateInterest);
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        _claim();
        _consolidate();
        _sell();

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        _claim();
        _pool();
        _stakeAll();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 toExitAmount = _amountNeeded.sub(totalAssets);

            IDInterest.Deposit memory depositInfo = getDepositInfo();
            integrator.withdraw(depositId, Math.min(toExitAmount, depositInfo.virtualTokenTotalSupply), hasMatured());
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        IDInterest.Deposit memory depositInfo = getDepositInfo();
        integrator.withdraw(depositId, depositInfo.virtualTokenTotalSupply, now > depositInfo.maturationTimestamp);
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
        string memory uri = nftDescriptor.constructTokenURI(INftDescriptor.URIParams(
                depositId,
                _newStrategy,
                "",
                ""
            ));

        nft.setTokenURI(
            depositId,
            uri);
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){
        return _amtInWei;
    }

    // pool want. Make sure to claim rewards prior to rollover
    function _pool() internal {
        uint loose = balanceOfWant();

        if (depositId != 0) {

            // if matured, rollover to a new nft so we can continue vesting
            if (hasMatured()) {
                uint newDepositId;
                (newDepositId, fixedRateInterest) = integrator.rolloverDeposit(depositId, uint64(now + maturationPeriod));
                depositId = uint64(newDepositId);
            }

            // top up the current deposit
            if (loose > 0) {
                fixedRateInterest = integrator.topupDeposit(depositId, loose);
            }
        } else {
            if (loose > 0) {
                (depositId, fixedRateInterest) = integrator.deposit(loose, uint64(now + maturationPeriod));
            }
        }
    }

    // claim mph. Make sure this always happens before _pool(), otherwise old depositId's rewards could be lost
    function _claim() internal {
        if (depositId != 0 && vestor.getVestWithdrawableAmount(depositId) > 0) {
            vestor.withdraw(depositId);
        }
    }

    // consolidate how much to stake vs unstake
    function _consolidate() internal {
        // values calculated before action so the actions can stay independent of each other
        uint toStake = balanceOfReward().mul(stakePercentage).div(basisMax);
        uint toUnstake = balanceOfStaked().mul(unstakePercentage).div(basisMax);

        if (toStake > 0) {
            stake.deposit(toStake);
        }
        if (toUnstake > 0) {
            stake.withdraw(toUnstake);
        }
    }

    function _stakeAll() internal {
        uint toStake = balanceOfReward();
        if (toStake > 0) {
            stake.deposit(toStake);
        }
    }

    // sell mph for want
    function _sell() internal {
        uint toSell = balanceOfReward();

        if (toSell > 0) {
            // sell
            IBancorRouter router = IBancorRouter(bancorRegistry.getAddress(routerNetwork));
            address[] memory paths = router.conversionPath(address(reward), address(want));
            reward.approve(address(router), 0);
            reward.approve(address(router), toSell);
            router.claimAndConvert2(paths, toSell, 0, vault.governance(), 0);
        }
    }


    // HELPERS //

    function balanceOfWant() public view returns (uint _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint _amount){
        return reward.balanceOf(address(this));
    }

    function balanceOfStaked() public view returns (uint _amount){
        return stake.balanceOf(address(this));
    }

    function getDepositInfo() public view returns (IDInterest.Deposit memory _deposit){
        return integrator.getDeposit(depositId);
    }

    function hasMatured() public view returns (bool){
        return now > getDepositInfo().maturationTimestamp;
    }

    function setMaturationPeriod(uint64 _maturationUnix) public onlyVaultManagers {
        require(_maturationUnix > 24 * 60 * 60);
        maturationPeriod = _maturationUnix;
    }

    // percentage of reward to keep and stake. Unstaked rewards would be sold immediately
    function setStakePercentage(uint _bips) public onlyVaultManagers {
        require(_bips <= basisMax);
        stakePercentage = _bips;
    }

    // percentage of stake to unstake and sell. Staked reward would remain within staking pool
    function setUnstakePercentage(uint _bips) public onlyVaultManagers {
        require(_bips <= basisMax);
        unstakePercentage = _bips;
    }

    function setRouterNetwork(bytes32 _network) public onlyVaultManagers {
        routerNetwork = _network;
    }

    function setMaxSlippage(uint _bips) public onlyVaultManagers {

    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4){
        require(tokenId <= type(uint64).max, "tokenId too large!");
        require(IDInterest(operator).stablecoin() == address(want), "wrong token!");
        require(depositId == 0, "deposit already exists!");
        depositId = uint64(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }


}
