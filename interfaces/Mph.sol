// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IVesting {
    struct Vest {
        address pool;
        uint64 depositID;
        uint64 lastUpdateTimestamp;
        uint256 accumulatedAmount;
        uint256 withdrawnAmount;
        uint256 vestAmountPerStablecoinPerSecond;
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) external;

    function depositIDToVestID(address _owner, uint64 _depositId) external view returns (uint64 _vestId);

    function getVestWithdrawableAmount(uint64 vestID) external view returns (uint256);

    function getVest(uint64 vestID) external view returns (Vest memory);

    function withdraw(uint64 vestID) external returns (uint256 withdrawnAmount);

    function token() external returns (address);

    function ownerOf(uint vestId) external view returns (address);
}

interface IMphMinter {
    function vesting02() external returns (address);
}

interface IDInterest {
    struct Deposit {
        uint256 virtualTokenTotalSupply; // depositAmount + interestAmount, behaves like a zero coupon bond
        uint256 interestRate; // interestAmount = interestRate * depositAmount
        uint256 feeRate; // feeAmount = feeRate * depositAmount
        uint256 averageRecordedIncomeIndex; // Average income index at time of deposit, used for computing deposit surplus
        uint64 maturationTimestamp; // Unix timestamp after which the deposit may be withdrawn, in seconds
        uint64 fundingID; // The ID of the associated Funding struct. 0 if not funded.
    }

    function mphMinter() external returns (address);

    function stablecoin() external returns (address);

    function depositNFT() external returns (address);

    /**
        @notice Create a deposit using `depositAmount` stablecoin that matures at timestamp `maturationTimestamp`.
        @dev The ERC-721 NFT representing deposit ownership is given to msg.sender
        @param depositAmount The amount of deposit, in stablecoin
        @param maturationTimestamp The Unix timestamp of maturation, in seconds
        @return depositID The ID of the created deposit
        @return interestAmount The amount of fixed-rate interest
     */
    function deposit(uint256 depositAmount, uint64 maturationTimestamp) external returns (uint64 depositID, uint256 interestAmount);

    /**
        @notice Create a deposit using `depositAmount` stablecoin that matures at timestamp `maturationTimestamp`.
        @dev The ERC-721 NFT representing deposit ownership is given to msg.sender
        @param depositAmount The amount of deposit, in stablecoin
        @param maturationTimestamp The Unix timestamp of maturation, in seconds
        @param minimumInterestAmount If the interest amount is less than this, revert
        @param uri The metadata URI for the minted NFT
        @return depositID The ID of the created deposit
        @return interestAmount The amount of fixed-rate interest
     */
    function deposit(
        uint256 depositAmount,
        uint64 maturationTimestamp,
        uint256 minimumInterestAmount,
        string calldata uri
    ) external returns (uint64 depositID, uint256 interestAmount);

    /**
    @notice Add `depositAmount` stablecoin to the existing deposit with ID `depositID`.
    @dev The interest rate for the topped up funds will be the current oracle rate.
    @param depositID The deposit to top up
    @param depositAmount The amount to top up, in stablecoin
    @return interestAmount The amount of interest that will be earned by the topped up funds at maturation
 */
    function topupDeposit(uint64 depositID, uint256 depositAmount) external returns (uint256 interestAmount);

    /**
        @notice Add `depositAmount` stablecoin to the existing deposit with ID `depositID`.
        @dev The interest rate for the topped up funds will be the current oracle rate.
        @param depositID The deposit to top up
        @param depositAmount The amount to top up, in stablecoin
        @param minimumInterestAmount If the interest amount is less than this, revert
        @return interestAmount The amount of interest that will be earned by the topped up funds at maturation
     */
    function topupDeposit(
        uint64 depositID,
        uint256 depositAmount,
        uint256 minimumInterestAmount
    ) external returns (uint256 interestAmount);


    /**
        @notice Withdraw all funds from deposit with ID `depositID` and use them
                to create a new deposit that matures at time `maturationTimestamp`
        @param depositID The deposit to roll over
        @param maturationTimestamp The Unix timestamp of the new deposit, in seconds
        @return newDepositID The ID of the new deposit
     */
    function rolloverDeposit(uint64 depositID, uint64 maturationTimestamp) external returns (uint256 newDepositID, uint256 interestAmount);

    /**
        @notice Withdraw all funds from deposit with ID `depositID` and use them
                to create a new deposit that matures at time `maturationTimestamp`
        @param depositID The deposit to roll over
        @param maturationTimestamp The Unix timestamp of the new deposit, in seconds
        @param minimumInterestAmount If the interest amount is less than this, revert
        @param uri The metadata URI of the NFT
        @return newDepositID The ID of the new deposit
     */
    function rolloverDeposit(
        uint64 depositID,
        uint64 maturationTimestamp,
        uint256 minimumInterestAmount,
        string calldata uri
    ) external returns (uint256 newDepositID, uint256 interestAmount);

    /**
        @notice Withdraws funds from the deposit with ID `depositID`.
        @dev Virtual tokens behave like zero coupon bonds, after maturation withdrawing 1 virtual token
             yields 1 stablecoin. The total supply is given by deposit.virtualTokenTotalSupply
        @param depositID the deposit to withdraw from
        @param virtualTokenAmount the amount of virtual tokens to withdraw
        @param early True if intend to withdraw before maturation, false otherwise
        @return withdrawnStablecoinAmount the amount of stablecoins withdrawn

        NOTE: @param virtualTokenAmount when premature amount takes into account the interest already. If you want to withdraw 10k amount,
        you must input 10,000 * interest amount. When mature, request exact amount 10k.
     */
    function withdraw(uint64 depositID, uint256 virtualTokenAmount, bool early) external returns (uint256 withdrawnStablecoinAmount);

    /**
        @notice Returns the Deposit struct associated with the deposit with ID
                `depositID`.
        @param depositID The ID of the deposit
        @return The deposit struct
     */
    function getDeposit(uint64 depositID) external view returns (Deposit memory);

    /**
      @notice Computes the amount of fixed-rate interest (before fees) that
              will be given to a deposit of `depositAmount` stablecoins that
              matures in `depositPeriodInSeconds` seconds.
      @param depositAmount The deposit amount, in stablecoins
      @param depositPeriodInSeconds The deposit period, in seconds
      @return interestAmount The amount of fixed-rate interest (before fees)
   */
    function calculateInterestAmount(
        uint256 depositAmount,
        uint256 depositPeriodInSeconds
    ) external returns (uint256 interestAmount);
}

// xMPH.sol
interface IStake is IERC20 {
    /**
    @notice Deposit MPH to get xMPH
    @dev The amount can't be 0
    @param _mphAmount The amount of MPH to deposit
    @return shareAmount The amount of xMPH minted
    */
    function deposit(uint256 _mphAmount) external returns (uint256 shareAmount);

    /**
        @notice Withdraw MPH using xMPH
        @dev The amount can't be 0
        @param _shareAmount The amount of xMPH to burn
        @return mphAmount The amount of MPH withdrawn
     */
    function withdraw(uint256 _shareAmount) external returns (uint256 mphAmount);

    function getPricePerFullShare() external view returns (uint256);
}

interface INft {
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) external;

    function contractURI() external view returns (string memory);

    function setTokenURI(uint256 tokenId, string calldata newURI) external;

}

interface INftDescriptor {
    struct URIParams {
        uint256 tokenId;
        address owner;
        string name;
        string symbol;
    }

    function constructTokenURI(URIParams memory params) external pure returns (string memory);
}