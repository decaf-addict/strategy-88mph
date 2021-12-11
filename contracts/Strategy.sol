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

import "../interfaces/Mph.sol";
import "./BaseStrategyWithSwapperEnabled.sol";

contract Strategy is BaseStrategyWithSwapperEnabled, IERC721Receiver {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    string internal strategyName;
    // deposit position nft
    INft public depositNft;
    // primary interface for entering/exiting protocol
    IDInterest public pool;
    // nft for redeeming mph that vests linearly
    IVesting public vestNft;
    bytes constant internal deposit = "deposit";
    bytes constant internal vest = "vest";
    uint64 public depositId;
    uint64 public maturationPeriod;
    address public oldStrategy;

    // For withdraws. Some protocol rounding reverts when withdrawing full amount, so we subtract a little bit from it
    uint public dust;
    // Decimal precision for withdraws
    uint public minWithdraw;

    uint constant internal basisMax = 10000;
    IERC20 public reward;
    bool internal isOriginal = true;
    uint constant private max = type(uint).max;

    // Trade slippage sent to ySwap
    uint public tradeSlippage;

    constructor(
        address _vault,
        address _pool,
        address _tradeFactory,
        string memory _strategyName
    )
    public BaseStrategyWithSwapperEnabled(_vault, _tradeFactory) {
        _initializeStrat(_vault, _pool, _tradeFactory, _strategyName);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _pool,
        address _tradeFactory,
        string memory _strategyName
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _pool, _tradeFactory, _strategyName);
    }

    function _initializeStrat(
        address _vault,
        address _pool,
        address _tradeFactory,
        string memory _strategyName
    ) internal {
        strategyName = _strategyName;
        pool = IDInterest(_pool);
        require(address(want) == pool.stablecoin(), "Wrong pool!");
        vestNft = IVesting(IMphMinter(pool.mphMinter()).vesting02());
        reward = IERC20(vestNft.token());
        depositNft = INft(pool.depositNFT());
        tradeFactory = _tradeFactory;
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0);

        maturationPeriod = 180 * 24 * 60 * 60;
        // we usually do 3k which is 0.3%
        tradeSlippage = 3_000;

        want.safeApprove(address(pool), max);
    }


    // VAULT OPERATIONS //

    function name() external view override returns (string memory) {
        return strategyName;
    }

    // fixed rate interest only unlocks after deposit has matured
    function estimatedTotalAssets() public view override returns (uint256) {
        uint depositWithInterest = getDepositInfo().virtualTokenTotalSupply;
        uint interestRate = getDepositInfo().interestRate;
        uint wants = balanceOfWant();
        // virtualTokenTotalSupply = deposit + fixed-rate interest. Before maturation, the fixed-rate interest is not withdrawable
        return wants.add(hasMatured() ? depositWithInterest : depositWithInterest.mul(1e18).div(interestRate.add(1e18)));
    }

    event Debug(string msg, uint value);

    function prepareReturn(uint256 _debtOutstanding) internal override returns (uint256 _profit, uint256 _loss, uint256 _debtPayment){
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        // collect fixed-rate apy if matured
        _profit = _collect();
        emit Debug("after collect", _profit);
        uint256 beforeWant = balanceOfWant();
        _claim();
        emit Debug("after claim", _profit);
        _sell();
        emit Debug("after sell", _profit);

        uint256 afterWant = balanceOfWant();

        _profit += afterWant.sub(beforeWant);

        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    // claim vested mph, pool loose wants
    function adjustPosition(uint256 _debtOutstanding) internal override {
        _claim();
        _pool();
    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        if (estimatedTotalAssets() <= _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 loose = balanceOfWant();
        if (_amountNeeded > loose) {
            uint toExitAmount = _amountNeeded.sub(loose);
            IDInterest.Deposit memory depositInfo = getDepositInfo();
            uint toExitVirtualAmount = toExitAmount.mul(depositInfo.interestRate.add(1e18)).div(1e18);
            uint amt = hasMatured() ? toExitAmount : toExitVirtualAmount;

            _poolWithdraw(amt);

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    // exit everything
    function liquidateAllPositions() internal override returns (uint256) {
        IDInterest.Deposit memory depositInfo = getDepositInfo();
        uint toExit = depositInfo.virtualTokenTotalSupply;
        _poolWithdraw(toExit);
        return balanceOfWant();
    }

    // transfer both nfts to new strategy
    function prepareMigration(address _newStrategy) internal override {
        depositNft.safeTransferFrom(address(this), _newStrategy, depositId, deposit);
        vestNft.safeTransferFrom(address(this), _newStrategy, vestId(), vest);
    }

    function protectedTokens() internal view override returns (address[] memory){}

    function ethToWant(uint256 _amtInWei) public view virtual override returns (uint256){
        return 0;
    }

    // INTERNAL OPERATIONS //

    // pool wants
    function _pool() internal {
        uint loose = balanceOfWant();

        // if loose amount is too small to generate interest due to loss of precision, deposits will revert
        uint interest = pool.calculateInterestAmount(loose, maturationPeriod);

        if (depositId != 0) {
            // top up the current deposit aka add more loose to the depositNft position
            if (loose > 0 && interest > 0) {
                pool.topupDeposit(depositId, loose);
            }
        } else {
            // if there's no depositId, we haven't opened a position yet
            if (loose > 0 && interest > 0) {
                // open a position with a fixed period. Fixed-rate yield can be collected after this period.
                (depositId,) = pool.deposit(loose, uint64(now + maturationPeriod));
            }
        }
    }

    // claim mph. Make sure this always happens before _pool(), otherwise old depositId's rewards could be lost
    function _claim() internal {
        if (depositId != 0 && balanceOfClaimableReward() > 0) {
            vestNft.withdraw(vestId());
        }
    }

    // Fixed rate interest can only be collected once depositNft has matured.
    // We collect this once matured.
    function _collect() internal returns (uint _profit){
        if (depositId != 0 && hasMatured()) {
            liquidateAllPositions();
            uint balance = balanceOfWant();
            uint debt = vault.strategies(address(this)).totalDebt;
            return balance > debt ? balance.sub(debt) : 0;
        } else {
            return 0;
        }
    }

    // sell mph for want using ySwaps
    function _sell() internal {
        uint toSell = balanceOfReward();
        if (toSell > 0) {
            uint256 _tokenAllowance = _tradeFactoryAllowance(address(reward));
            emit Debug("allowance", _tokenAllowance);
            emit Debug("toSell", toSell);
            if (toSell > _tokenAllowance) {
                uint id = _createTrade(address(reward), address(want), toSell - _tokenAllowance, tradeSlippage, block.timestamp + 604800);
                emit Debug("id", id);
            }
        }
    }

    // withdraw from pool
    function _poolWithdraw(uint _amount) internal {
        // ensure that withdraw amount is more than dust and minWithdraw amount, otherwise, some protocols will revert
        if (_amount > dust && _amount.sub(dust) > minWithdraw) {
            pool.withdraw(depositId, _amount.sub(dust), !hasMatured());
        }
    }

    // HELPERS //

    function balanceOfWant() public view returns (uint _amount){
        return want.balanceOf(address(this));
    }

    function balanceOfReward() internal returns (uint _amount){
        return reward.balanceOf(address(this));
    }

    function balanceOfClaimableReward() public view returns (uint _amount){
        return vestNft.getVestWithdrawableAmount(vestId());
    }

    function getDepositInfo() public view returns (IDInterest.Deposit memory _deposit){
        return pool.getDeposit(depositId);
    }

    function getVest() public view returns (IVesting.Vest memory _vest){
        return vestNft.getVest(vestId());
    }

    function hasMatured() public view returns (bool){
        return now > getDepositInfo().maturationTimestamp;
    }

    function vestId() public view returns (uint64 _vestId){
        return vestNft.depositIDToVestID(address(pool), depositId);
    }

    // SETTERS //

    function setMaturationPeriod(uint64 _maturationUnix) public onlyVaultManagers {
        require(_maturationUnix > 24 * 60 * 60);
        maturationPeriod = _maturationUnix;
    }

    // For migration. This acts as a password so random nft drops won't mess up the depositId
    function setOldStrategy(address _oldStrategy) public onlyVaultManagers {
        oldStrategy = _oldStrategy;
    }

    // Some protocol pools don't allow perfectly full withdrawal. Need to subtract by dust
    function setDust(uint _dust) public onlyVaultManagers {
        dust = _dust;
    }

    // Some protocol pools enforce a minimum amount withdraw, like cTokens w/ different decimal places.
    function setMinWithdraw(uint _minWithdraw) public onlyVaultManagers {
        minWithdraw = _minWithdraw;
    }

    function setTradeSlippage(uint256 _tradeSlippage) external onlyAuthorized {
        tradeSlippage = _tradeSlippage;
    }

    // only receive nft from oldStrategy otherwise, random nfts will mess up the depositId
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4){
        if (from == oldStrategy && keccak256(data) == keccak256(deposit)) {
            depositId = uint64(tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
