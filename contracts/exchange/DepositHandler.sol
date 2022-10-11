// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../role/RoleModule.sol";
import "../events/EventEmitter.sol";
import "../feature/FeatureUtils.sol";

import "../market/Market.sol";
import "../market/MarketStore.sol";
import "../market/MarketToken.sol";

import "../deposit/Deposit.sol";
import "../deposit/DepositStore.sol";
import "../deposit/DepositUtils.sol";
import "../oracle/Oracle.sol";
import "../oracle/OracleModule.sol";

contract DepositHandler is ReentrancyGuard, RoleModule, OracleModule {

    DataStore immutable dataStore;
    EventEmitter immutable eventEmitter;
    DepositStore immutable depositStore;
    MarketStore immutable marketStore;
    Oracle immutable oracle;
    FeeReceiver immutable feeReceiver;

    constructor(
        RoleStore _roleStore,
        DataStore _dataStore,
        EventEmitter _eventEmitter,
        DepositStore _depositStore,
        MarketStore _marketStore,
        Oracle _oracle,
        FeeReceiver _feeReceiver
    ) RoleModule(_roleStore) {
        dataStore = _dataStore;
        eventEmitter = _eventEmitter;
        depositStore = _depositStore;
        marketStore = _marketStore;
        oracle = _oracle;
        feeReceiver = _feeReceiver;
    }

    receive() external payable {
        require(msg.sender == EthUtils.weth(dataStore), "DepositHandler: invalid sender");
    }

    function createDeposit(
        address account,
        DepositUtils.CreateDepositParams memory params
    ) external nonReentrant onlyController returns (bytes32) {
        FeatureUtils.validateFeature(dataStore, Keys.createDepositFeatureKey(address(this)));

        return DepositUtils.createDeposit(
            dataStore,
            eventEmitter,
            depositStore,
            marketStore,
            account,
            params
        );
    }

    function executeDeposit(
        bytes32 key,
        OracleUtils.SetPricesParams memory oracleParams
    ) external nonReentrant onlyOrderKeeper {
        uint256 startingGas = gasleft();

        try this._executeDeposit(
            key,
            oracleParams,
            msg.sender,
            startingGas
        ) {
        } catch Error(string memory reason) {
            // revert instead of cancel if the reason for failure is due to oracle params
            if (keccak256(abi.encodePacked(reason)) == Keys.ORACLE_ERROR_KEY) {
                revert(reason);
            }

            DepositUtils.cancelDeposit(
                dataStore,
                eventEmitter,
                depositStore,
                marketStore,
                key,
                msg.sender,
                startingGas
            );
        } catch {
            DepositUtils.cancelDeposit(
                dataStore,
                eventEmitter,
                depositStore,
                marketStore,
                key,
                msg.sender,
                startingGas
            );
        }
    }

    function _executeDeposit(
        bytes32 key,
        OracleUtils.SetPricesParams memory oracleParams,
        address keeper,
        uint256 startingGas
    ) public
        onlySelf
        withOraclePrices(oracle, dataStore, eventEmitter, oracleParams)
    {
        FeatureUtils.validateFeature(dataStore, Keys.executeDepositFeatureKey(address(this)));

        uint256[] memory oracleBlockNumbers = OracleUtils.getUncompactedOracleBlockNumbers(
            oracleParams.compactedOracleBlockNumbers,
            oracleParams.tokens.length
        );

        DepositUtils.ExecuteDepositParams memory params = DepositUtils.ExecuteDepositParams(
            dataStore,
            eventEmitter,
            depositStore,
            marketStore,
            oracle,
            feeReceiver,
            key,
            oracleBlockNumbers,
            keeper,
            startingGas
        );

        DepositUtils.executeDeposit(params);
    }
}
