// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {
    IERC721Receiver
} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import "../interfaces/Mph.sol";

interface ITradeFactory {
    function enable(address, address) external;

    function disable(address, address) external;
}

interface IPercentageFeeModel {
    function getEarlyWithdrawFeeAmount(
        address pool,
        uint64 depositID,
        uint256 withdrawnDepositAmount
    ) external view returns (uint256 feeAmount);
}

contract Strategy is BaseStrategy, IERC721Receiver {
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
    bytes internal constant DEPOSIT = "deposit";
    bytes internal constant VEST = "vest";
    uint64 public depositId;
    uint64 public maturationPeriod;
    address public oldStrategy;

    // Decimal precision for withdraws
    uint256 public minWithdraw;
    bool public allowEarlyWithdrawFee;

    uint256 internal constant basisMax = 10000;
    IERC20 public reward;
    uint256 private constant max = type(uint256).max;

    address public keep;
    uint256 public keepBips;

    ITradeFactory public tradeFactory;

    constructor(
        address _vault,
        address _pool,
        string memory _strategyName
    )
    public BaseStrategy(_vault) {
        _initializeStrat(_vault, _pool, _strategyName);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _pool,
        string memory _strategyName
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_vault, _pool, _strategyName);
    }

    function _initializeStrat(
        address _vault,
        address _pool,
        string memory _strategyName
    ) internal {
        strategyName = _strategyName;
        pool = IDInterest(_pool);
        require(address(want) == pool.stablecoin(), "Wrong pool!");
        vestNft = IVesting(IMphMinter(pool.mphMinter()).vesting02());
        reward = IERC20(vestNft.token());
        depositNft = INft(pool.depositNFT());
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0);

        // default 5 days
        maturationPeriod = 5 * 24 * 60 * 60;

        want.safeApprove(address(pool), max);

        // 0% to chad by default
        keep = governance();
        keepBips = 0;
    }

    // VAULT OPERATIONS //
    function name() external view override returns (string memory) {
        return strategyName;
    }

    // fixed rate interest only unlocks after deposit has matured
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 totalAssets = estimatedTotalAssets();

        _profit = totalAssets > totalDebt ? totalAssets.sub(totalDebt) : 0;

        uint256 freed;

        if (hasMatured()) {
            freed = liquidateAllPositions();
            _loss = _debtOutstanding > freed ? _debtOutstanding.sub(freed) : 0;
        } else {
            uint256 toLiquidate = _debtOutstanding.add(_profit);
            if (toLiquidate > 0) {
                (freed, _loss) = liquidatePosition(toLiquidate);
            }
        }

        _debtPayment = Math.min(_debtOutstanding, freed);

        // net out PnL
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }

        if (hasMatured()) {
            depositId = 0;
        }
    }

    // claim vested mph, pool loose wants
    function adjustPosition(uint256 _debtOutstanding) internal override {
        _claim();
        _invest();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        if (_amountNeeded > 0) {
            uint256 loose = balanceOfWant();
            if (_amountNeeded > loose) {
                uint256 toExitAmount = _amountNeeded.sub(loose);
                IDInterest.Deposit memory depositInfo = getDepositInfo();
                uint256 toExitVirtualAmount =
                    toExitAmount.mul(depositInfo.interestRate.add(1e18)).div(
                        1e18
                    );

                _poolWithdraw(toExitVirtualAmount);

                _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
                _loss = _amountNeeded.sub(_liquidatedAmount);
            } else {
                _liquidatedAmount = _amountNeeded;
                _loss = 0;
            }
        }
    }

    // exit everything
    function liquidateAllPositions() internal override returns (uint256) {
        IDInterest.Deposit memory depositInfo = getDepositInfo();
        _poolWithdraw(depositInfo.virtualTokenTotalSupply);
        return balanceOfWant();
    }

    // transfer both nfts to new strategy
    function prepareMigration(address _newStrategy) internal override {
        depositNft.safeTransferFrom(
            address(this),
            _newStrategy,
            depositId,
            DEPOSIT
        );
        vestNft.safeTransferFrom(address(this), _newStrategy, vestId(), VEST);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return 0;
    }

    // INTERNAL OPERATIONS //

    function closeEpoch() external onlyEmergencyAuthorized {
        _closeEpoch();
    }

    function _closeEpoch() internal {
        liquidateAllPositions();
    }

    function invest() external onlyVaultManagers {
        _invest();
    }

    // pool wants
    function _invest() internal {
        uint256 loose = balanceOfWant();

        if (depositId != 0) {
            // top up the current deposit aka add more loose to the depositNft position.
            // If matured, no action
            if (loose > 0 && !hasMatured()) {
                pool.topupDeposit(depositId, loose);
            }
        } else {
            // if loose amount is too small to generate interest due to loss of precision, deposits will revert
            uint256 futureInterest =
                pool.calculateInterestAmount(loose, maturationPeriod);

            // if there's no depositId, we haven't opened a position yet
            if (loose > 0 && futureInterest > 0) {
                // open a position with a fixed period. Fixed-rate yield can be collected after this period.
                (depositId, ) = pool.deposit(
                    loose,
                    uint64(now + maturationPeriod)
                );
            }
        }
    }

    function claim() external onlyVaultManagers {
        _claim();
    }

    // claim mph. Make sure this always happens before _pool(), otherwise old depositId's rewards could be lost
    function _claim() internal {
        uint256 _rewardBalanceBeforeClaim = balanceOfReward();
        if (depositId != 0 && balanceOfClaimableReward() > 0) {
            vestNft.withdraw(vestId());

            uint256 _rewardAmountToKeep =
                balanceOfReward()
                    .sub(_rewardBalanceBeforeClaim)
                    .mul(keepBips)
                    .div(basisMax);
            if (_rewardAmountToKeep > 0) {
                reward.safeTransfer(keep, _rewardAmountToKeep);
            }
        }
    }

    function poolWithdraw(uint256 _virtualAmount) external onlyVaultManagers {
        _poolWithdraw(_virtualAmount);
    }

    // withdraw from pool.
    function _poolWithdraw(uint256 _virtualAmount) internal {
        // if early withdraw and we don't allow fees, enforce that there's no fees.
        // This makes sure that we don't get tricked by MPH with empty promises of waived fees.
        // Otherwise we can lose some principal
        if (!hasMatured() && !allowEarlyWithdrawFee) {
            require(getEarlyWithdrawFee() == 0, "!free");
        }
        // ensure that withdraw amount is more than minWithdraw amount, otherwise some protocols will revert
        if (_virtualAmount > minWithdraw) {
            pool.withdraw(depositId, _virtualAmount, !hasMatured());
        }
    }

    function overrideDepositId(uint64 _id) external onlyVaultManagers {
        depositId = _id;
    }

    // HELPERS //

    // virtualTokenTotalSupply = deposit + fixed-rate interest. Before maturation, the fixed-rate interest is not withdrawable
    function balanceOfPooled() public view returns (uint256 _amount) {
        if (depositId != 0) {
            uint256 depositWithInterest =
                getDepositInfo().virtualTokenTotalSupply;
            uint256 interestRate = getDepositInfo().interestRate;
            uint256 depositWithoutInterest =
                depositWithInterest.mul(1e18).div(interestRate.add(1e18));
            return hasMatured() ? depositWithInterest : depositWithoutInterest;
        }
    }

    function balanceOfWant() public view returns (uint256 _amount) {
        return want.balanceOf(address(this));
    }

    function balanceOfReward() public view returns (uint256 _amount) {
        return reward.balanceOf(address(this));
    }

    function balanceOfClaimableReward() public view returns (uint256 _amount) {
        return vestNft.getVestWithdrawableAmount(vestId());
    }

    function getDepositInfo()
        public
        view
        returns (IDInterest.Deposit memory _deposit)
    {
        return pool.getDeposit(depositId);
    }

    function getVest() public view returns (IVesting.Vest memory _vest) {
        return vestNft.getVest(vestId());
    }

    function hasMatured() public view returns (bool) {
        return
            depositId != 0 ? now > getDepositInfo().maturationTimestamp : false;
    }

    function vestId() public view returns (uint64 _vestId) {
        return vestNft.depositIDToVestID(address(pool), depositId);
    }

    // fee on full withdrawal
    function getEarlyWithdrawFee() public view returns (uint256 _feeAmount) {
        return
            IPercentageFeeModel(pool.feeModel()).getEarlyWithdrawFeeAmount(
                address(pool),
                depositId,
                estimatedTotalAssets()
            );
    }

    // SETTERS //

    function setTradeFactory(address _tradeFactory) public onlyGovernance {
        _setTradeFactory(_tradeFactory);
    }

    function _setTradeFactory(address _tradeFactory) internal {
        tradeFactory = ITradeFactory(_tradeFactory);
        reward.safeApprove(address(tradeFactory), max);
        tradeFactory.enable(address(reward), address(want));
    }

    function disableTradeFactory() public onlyVaultManagers {
        _disableTradeFactory();
    }

    function _disableTradeFactory() internal {
        delete tradeFactory;
        reward.safeApprove(address(tradeFactory), 0);
        tradeFactory.disable(address(reward), address(want));
    }

    function setMaturationPeriod(uint64 _maturationUnix)
        public
        onlyVaultManagers
    {
        // minimum 1 day
        require(_maturationUnix > 24 * 60 * 60);
        maturationPeriod = _maturationUnix;
    }

    // For migration. This acts as a password so random nft drops won't mess up the depositId
    function setOldStrategy(address _oldStrategy) public onlyVaultManagers {
        oldStrategy = _oldStrategy;
    }

    // Some protocol pools enforce a minimum amount withdraw, like cTokens w/ different decimal places.
    function setMinWithdraw(uint256 _minWithdraw) public onlyVaultManagers {
        minWithdraw = _minWithdraw;
    }

    function setAllowWithdrawFee(bool _allow) public onlyVaultManagers {
        allowEarlyWithdrawFee = _allow;
    }

    function setKeepParams(address _keep, uint256 _keepBips)
        external
        onlyGovernance
    {
        require(keepBips <= basisMax);
        keep = _keep;
        keepBips = _keepBips;
    }

    // only receive nft from oldStrategy otherwise, random nfts will mess up the depositId
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        if (
            msg.sender == address(depositNft) &&
            from == oldStrategy &&
            keccak256(data) == keccak256(DEPOSIT)
        ) {
            depositId = uint64(tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
