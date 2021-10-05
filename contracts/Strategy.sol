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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "../interfaces/Mph.sol";
import "../interfaces/Bancor.sol";
import "../interfaces/Weth.sol";


contract Strategy is BaseStrategy, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    INft public nft;
    IDInterest public pool;
    IVesting public vestor;
    IStake public stake;
    IBancorRegistry public bancorRegistry;
    bytes32 public routerNetwork;
    string constant internal deposit = "deposit";
    string constant internal vest = "vest";

    uint64 public depositId;
    uint public fixedRateInterest;

    uint public stakePercentage;
    uint public unstakePercentage;
    uint constant basisMax = 10000;
    IERC20 public reward;
    uint64 public maturationPeriod = 180 * 24 * 60 * 60;
    bool internal isOriginal = true;
    uint constant private max = type(uint).max;
    address public oldStrategy;

    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IWETH9 public constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    constructor(
        address _vault,
        address _pool,
        address _stakeToken,
        address _bancorRegistry
    )
    public BaseStrategy(_vault){
        _initializeStrat(_vault, _pool, _stakeToken, _bancorRegistry);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _pool,
        address _stakeToken,
        address _bancorRegistry
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _pool, _stakeToken, _bancorRegistry);
    }

    function _initializeStrat(
        address _vault,
        address _pool,
        address _stakeToken,
        address _bancorRegistry

    ) internal {
        pool = IDInterest(_pool);
        require(address(want) == pool.stablecoin(), "Wrong pool!");
        vestor = IVesting(IMphMinter(pool.mphMinter()).vesting02());
        reward = IERC20(vestor.token());
        nft = INft(pool.depositNFT());
        stake = IStake(_stakeToken);
        //        healthCheck = address(0xDDCea799fF1699e98EDF118e0629A974Df7DF012);
        bancorRegistry = IBancorRegistry(_bancorRegistry);
        routerNetwork = bytes32("BancorNetwork");

        // USDT is non ERC20 compliant, can't use normal approve
        want.approve(address(pool), max);
        reward.approve(address(stake), max);

        stakePercentage = 2000;
        unstakePercentage = 8000;
    }

    event Cloned(address indexed clone);

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _pool,
        address _stakeToken,
        address _bancorRegistry
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

        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper, _pool, _stakeToken, _bancorRegistry);
        emit Cloned(newStrategy);
    }


    function name() external view override returns (string memory) {
        return "88-MPH Staker";
    }

    // fixed rate interest only comes after deposit has matured
    function estimatedTotalAssets() public view override returns (uint256) {
        uint depositWithInterest = getDepositInfo().virtualTokenTotalSupply;
        uint interestRate = getDepositInfo().interestRate;
        uint wants = balanceOfWant();
        return wants.add(hasMatured() ? depositWithInterest : depositWithInterest.mul(1e18).div(interestRate.add(1e18)));
    }

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        _collect();
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
        uint256 loose = balanceOfWant();
        if (_amountNeeded > loose) {
            uint toExitAmount = _amountNeeded.sub(loose);
            IDInterest.Deposit memory depositInfo = getDepositInfo();
            uint toExitVirtualAmount = toExitAmount.mul(depositInfo.interestRate.add(1e18)).div(1e18);
            pool.withdraw(depositId, hasMatured() ? toExitAmount : toExitVirtualAmount, !hasMatured());

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        IDInterest.Deposit memory depositInfo = getDepositInfo();
        pool.withdraw(depositId, depositInfo.virtualTokenTotalSupply, !(now > depositInfo.maturationTimestamp));
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        nft.safeTransferFrom(address(this), _newStrategy, depositId, abi.encode(deposit));
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){
        return _amtInWei;
    }

    // pool want. Make sure to claim rewards prior to rollover
    function _pool() internal {
        uint loose = balanceOfWant();

        // if loose amount is too small to generate interest due to loss of precision, deposits will revert
        uint interest = pool.calculateInterestAmount(loose, maturationPeriod);

        if (depositId != 0) {

            // if matured, rollover to a new nft so we can continue vesting
            if (hasMatured()) {
                uint newDepositId;
                (newDepositId,) = pool.rolloverDeposit(depositId, uint64(now + maturationPeriod));
                depositId = uint64(newDepositId);
            }

            // top up the current deposit
            if (loose > 0 && interest > 0) {
                pool.topupDeposit(depositId, loose);
            }
        } else {
            if (loose > 0 && interest > 0) {
                (depositId,) = pool.deposit(loose, uint64(now + maturationPeriod));
            }
        }
    }

    // claim mph. Make sure this always happens before _pool(), otherwise old depositId's rewards could be lost
    function _claim() public {
        if (depositId != 0 && vestor.getVestWithdrawableAmount(vestId()) > 0) {
            vestor.withdraw(vestId());
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

    // collect the fixed-rate interest once it has rolled over
    function _collect() internal {
        if (depositId != 0 && !hasMatured()) {
            uint eta = estimatedTotalAssets();
            uint debt = vault.strategies(address(this)).totalDebt;
            if (eta > debt) {
                uint toExitAmount = eta.sub(debt);
                IDInterest.Deposit memory depositInfo = getDepositInfo();
                uint toExitVirtualAmount = toExitAmount.mul(depositInfo.interestRate.add(1e18)).div(1e18);
                pool.withdraw(depositId, toExitVirtualAmount, !hasMatured());
            }
        }
    }

    // sell mph for want
    function _sell() internal {
        uint toSell = balanceOfReward();
        uint decReward = ERC20(address(reward)).decimals();
        uint decWant = ERC20(address(want)).decimals();
        if (toSell > 10 ** (decReward > decWant ? decReward.sub(decWant) : 0)) {
            // sell

            bool isWeth = address(want) == address(weth);
            IBancorRouter router = IBancorRouter(bancorRegistry.getAddress(routerNetwork));
            address[] memory paths = router.conversionPath(address(reward), isWeth ? eth : address(want));
            reward.approve(address(router), 0);
            reward.approve(address(router), toSell);

            if (isWeth) {
                router.convert(paths, toSell, 1);
                uint eths = address(this).balance;
                weth.withdraw(eths);
            } else {
                router.claimAndConvert(paths, toSell, 1);
            }
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
        return pool.getDeposit(depositId);
    }

    function getVest() public view returns (IVesting.Vest memory _vest){
        return vestor.getVest(vestId());
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

    function vestId() public view returns (uint64 _vestId){
        return vestor.depositIDToVestID(address(pool), depositId);
    }

    // for migration. This acts as a password so random nft drops won't messed up the depositId
    function setOldStrategy(address _oldStrategy) public onlyVaultManagers {
        oldStrategy = _oldStrategy;
    }

    // only receive nft from oldStrategy otherwise, random nfts will mess up the depositId
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4){
        if (from == oldStrategy) {
            depositId = uint64(tokenId);
            return IERC721Receiver.onERC721Received.selector;
        }
        return 0;
    }

    receive() external payable {}
}
