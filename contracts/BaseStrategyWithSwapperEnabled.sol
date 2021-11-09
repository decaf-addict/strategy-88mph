// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {SafeERC20, SafeMath, IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


interface ISwapperEnabled {
  event TradeFactorySet(address indexed _tradeFactory);

  function tradeFactory() external returns (address _tradeFactory);

  function setTradeFactory(address _tradeFactory) external;

  function createTrade(
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    uint256 _deadline
  ) external returns (uint256 _id);

  function executeTrade(
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage
  ) external returns (uint256 _receivedAmount);

  function executeTrade(
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    bytes calldata _data
  ) external returns (uint256 _receivedAmount);


  function cancelPendingTrades(uint256[] calldata _pendingTrades) external;
}

// Part: ITradeFactoryExecutor

interface ITradeFactoryExecutor {
  event SyncTradeExecuted(
    address indexed _strategy,
    address indexed _swapper,
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    bytes _data,
    uint256 _receivedAmount
  );

  event AsyncTradeExecuted(uint256 indexed _id, uint256 _receivedAmount);

  event AsyncTradeExpired(uint256 indexed _id);

  event SwapperAndTokenEnabled(address indexed _swapper, address _token);

  function approvedTokensBySwappers(address _swapper) external view returns (address[] memory _tokens);

  function execute(
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    bytes calldata _data
  ) external returns (uint256 _receivedAmount);

  function execute(uint256 _id, bytes calldata _data) external returns (uint256 _receivedAmount);

  function expire(uint256 _id) external returns (uint256 _freedAmount);
}

// Part: ITradeFactoryPositionsHandler

interface ITradeFactoryPositionsHandler {
  struct Trade {
    uint256 _id;
    address _strategy;
    address _swapper;
    address _tokenIn;
    address _tokenOut;
    uint256 _amountIn;
    uint256 _maxSlippage;
    uint256 _deadline;
  }

  event TradeCreated(
    uint256 indexed _id,
    address _strategy,
    address _swapper,
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    uint256 _deadline
  );

  event TradeCanceled(address indexed _strategy, uint256 indexed _id);

  event TradesCanceled(address indexed _strategy, uint256[] _ids);

  event TradesSwapperChanged(address indexed _strategy, uint256[] _ids, address _newSwapper);

  function pendingTradesById(uint256)
    external
    view
    returns (
      uint256 _id,
      address _strategy,
      address _swapper,
      address _tokenIn,
      address _tokenOut,
      uint256 _amountIn,
      uint256 _maxSlippage,
      uint256 _deadline
    );

  function pendingTradesIds() external view returns (uint256[] memory _pendingIds);

  function pendingTradesIds(address _strategy) external view returns (uint256[] memory _pendingIds);

  function create(
    address _tokenIn,
    address _tokenOut,
    uint256 _amountIn,
    uint256 _maxSlippage,
    uint256 _deadline
  ) external returns (uint256 _id);

  function cancelPending(uint256 _id) external;

  function cancelAllPending() external returns (uint256[] memory _canceledTradesIds);

  function setStrategyAsyncSwapperAsAndChangePending(
    address _strategy,
    address _swapper,
    bool _migrateSwaps
  ) external returns (uint256[] memory _changedSwapperIds);

  function changeStrategyPendingTradesSwapper(address _strategy, address _swapper) external returns (uint256[] memory _changedSwapperIds);
}


abstract contract SwapperEnabled is ISwapperEnabled {
    using SafeERC20 for IERC20;

    address public override tradeFactory;

    constructor(address _tradeFactory) public {
        _setTradeFactory(_tradeFactory);
    }

    // onlyMultisig:
    function _setTradeFactory(address _tradeFactory) internal {
        tradeFactory = _tradeFactory;
        emit TradeFactorySet(_tradeFactory);
    }

    function _createTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage,
        uint256 _deadline
    ) internal returns (uint256 _id) {
        IERC20(_tokenIn).safeIncreaseAllowance(tradeFactory, _amountIn);
        return ITradeFactoryPositionsHandler(tradeFactory).create(_tokenIn, _tokenOut, _amountIn, _maxSlippage, _deadline);
    }

    function _executeTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage
    ) internal returns (uint256 _receivedAmount) {
        IERC20(_tokenIn).safeIncreaseAllowance(tradeFactory, _amountIn);
        return ITradeFactoryExecutor(tradeFactory).execute(_tokenIn, _tokenOut, _amountIn, _maxSlippage, '');
    }

    function _executeTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage,
        bytes calldata _data
    ) internal returns (uint256 _receivedAmount) {
        IERC20(_tokenIn).safeIncreaseAllowance(tradeFactory, _amountIn);
        return ITradeFactoryExecutor(tradeFactory).execute(_tokenIn, _tokenOut, _amountIn, _maxSlippage, _data);
    }

    // onlyStrategist or multisig:
    function _cancelPendingTrades(uint256[] calldata _pendingTrades) internal {
        for (uint256 i; i < _pendingTrades.length; i++) {
            _cancelPendingTrade(_pendingTrades[i]);
        }
    }

    function _cancelPendingTrade(uint256 _pendingTradeId) internal {
        (, , , address _tokenIn, , uint256 _amountIn, ,) = ITradeFactoryPositionsHandler(tradeFactory).pendingTradesById(_pendingTradeId);
        IERC20(_tokenIn).safeDecreaseAllowance(tradeFactory, _amountIn);
        ITradeFactoryPositionsHandler(tradeFactory).cancelPending(_pendingTradeId);
    }

    function _tradeFactoryAllowance(address _token) internal view returns (uint256 _allowance) {
        return IERC20(_token).allowance(address(this), tradeFactory);
    }
}

abstract contract BaseStrategyWithSwapperEnabled is BaseStrategy, SwapperEnabled {
    constructor(address _vault, address _tradeFactory) BaseStrategy(_vault) SwapperEnabled(_tradeFactory) public {}

    // SwapperEnabled onlyGovernance methods
    function setTradeFactory(address _tradeFactory) external override onlyGovernance {
        _setTradeFactory(_tradeFactory);
    }

    function createTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage,
        uint256 _deadline
    ) external override onlyGovernance returns (uint256 _id) {
        return _createTrade(_tokenIn, _tokenOut, _amountIn, _maxSlippage, _deadline);
    }

    function executeTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage
    ) external override returns (uint256 _receivedAmount) {
        return _executeTrade(_tokenIn, _tokenOut, _amountIn, _maxSlippage);
    }

    function executeTrade(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _maxSlippage,
        bytes calldata _data
    ) external override returns (uint256 _receivedAmount) {
        return _executeTrade(_tokenIn, _tokenOut, _amountIn, _maxSlippage, _data);
    }

    function cancelPendingTrades(uint256[] calldata _pendingTrades) external override onlyAuthorized {
        _cancelPendingTrades(_pendingTrades);
    }
}
