// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../utils/Precision.sol";

import "../data/DataStore.sol";
import "../event/EventEmitter.sol";
import "../fee/FeeReceiver.sol";

import "../oracle/Oracle.sol";
import "../pricing/PositionPricingUtils.sol";

import "./Position.sol";
import "./PositionStore.sol";
import "./PositionUtils.sol";
import "../order/OrderBaseUtils.sol";

library IncreasePositionUtils {
    using SafeCast for uint256;
    using SafeCast for int256;

    using Position for Position.Props;
    using Order for Order.Props;
    using Price for Price.Props;

    struct IncreasePositionParams {
        DataStore dataStore;
        EventEmitter eventEmitter;
        PositionStore positionStore;
        Oracle oracle;
        FeeReceiver feeReceiver;
        IReferralStorage referralStorage;
        Market.Props market;
        Order.Props order;
        Position.Props position;
        bytes32 positionKey;
        address collateralToken;
        uint256 collateralDeltaAmount;
    }

    struct _IncreasePositionCache {
        int256 collateralDeltaAmount;
        int256 priceImpactUsd;
        uint256 executionPrice;
        int256 priceImpactAmount;
        uint256 sizeDeltaInTokens;
        uint256 nextPositionSizeInUsd;
        uint256 nextPositionBorrowingFactor;
    }

    error InsufficientCollateralAmount();

    function increasePosition(IncreasePositionParams memory params) external {
        Position.Props memory position = params.position;
        position.account = params.order.account();
        position.market = params.order.market();
        position.collateralToken = params.collateralToken;
        position.isLong = params.order.isLong();

        MarketUtils.MarketPrices memory prices = MarketUtils.getMarketPricesForPosition(
            params.market,
            params.oracle
        );

        MarketUtils.updateFundingAmountPerSize(
            params.dataStore,
            prices,
            params.market.marketToken,
            params.market.longToken,
            params.market.shortToken
        );

        MarketUtils.updateCumulativeBorrowingFactor(
            params.dataStore,
            params.market.marketToken,
            params.market.longToken,
            params.market.shortToken,
            prices,
            position.isLong
        );

        _IncreasePositionCache memory cache;
        PositionPricingUtils.PositionFees memory fees;
        (cache.collateralDeltaAmount, fees) = processCollateral(
            params,
            prices,
            position,
            params.collateralDeltaAmount.toInt256()
        );

        if (cache.collateralDeltaAmount < 0 && position.collateralAmount < SafeCast.toUint256(-cache.collateralDeltaAmount)) {
            revert InsufficientCollateralAmount();
        }
        position.collateralAmount = Calc.sum(position.collateralAmount, cache.collateralDeltaAmount);

        cache.priceImpactUsd = PositionPricingUtils.getPriceImpactUsd(
            PositionPricingUtils.GetPriceImpactUsdParams(
                params.dataStore,
                params.market.marketToken,
                params.market.longToken,
                params.market.shortToken,
                params.order.sizeDeltaUsd().toInt256(),
                params.order.isLong()
            )
        );

        // cap price impact usd based on the amount available in the position impact pool
        cache.priceImpactUsd = MarketUtils.getCappedPositionImpactUsd(
            params.dataStore,
            params.market.marketToken,
            prices.indexTokenPrice,
            cache.priceImpactUsd
        );

        cache.executionPrice = OrderBaseUtils.getExecutionPrice(
            params.oracle.getCustomPrice(params.market.indexToken),
            params.order.sizeDeltaUsd(),
            cache.priceImpactUsd,
            params.order.acceptablePrice(),
            position.isLong,
            true
        );

        cache.priceImpactAmount = PositionPricingUtils.getPriceImpactAmount(
            params.order.sizeDeltaUsd(),
            cache.executionPrice,
            prices.indexTokenPrice.max,
            position.isLong,
            true
        );

        // if there is a positive impact, the impact pool amount should be reduced
        // if there is a negative impact, the impact pool amount should be increased
        MarketUtils.applyDeltaToPositionImpactPool(
            params.dataStore,
            params.eventEmitter,
            params.market.marketToken,
            -cache.priceImpactAmount
        );

        if (position.isLong) {
            // round the number of tokens for long positions down
            cache.sizeDeltaInTokens = params.order.sizeDeltaUsd() / cache.executionPrice;
        } else {
            // round the number of tokens for short positions up
            cache.sizeDeltaInTokens = Calc.roundUpDivision(params.order.sizeDeltaUsd(), cache.executionPrice);
        }
        cache.nextPositionSizeInUsd = position.sizeInUsd + params.order.sizeDeltaUsd();
        cache.nextPositionBorrowingFactor = MarketUtils.getCumulativeBorrowingFactor(params.dataStore, params.market.marketToken, position.isLong);

        MarketUtils.updateTotalBorrowing(
            params.dataStore,
            params.market.marketToken,
            position.isLong,
            position.borrowingFactor,
            position.sizeInUsd,
            cache.nextPositionSizeInUsd,
            cache.nextPositionBorrowingFactor
        );

        position.sizeInUsd = cache.nextPositionSizeInUsd;
        position.sizeInTokens += cache.sizeDeltaInTokens;
        if (!fees.hasPendingLongTokenFundingFee) {
            position.longTokenFundingAmountPerSize = fees.latestLongTokenFundingAmountPerSize;
        }
        if (!fees.hasPendingShortTokenFundingFee) {
            position.shortTokenFundingAmountPerSize = fees.latestShortTokenFundingAmountPerSize;
        }

        if (fees.longTokenFundingFeeAmount > 0) {
            MarketUtils.incrementClaimableFundingAmount(
                params.dataStore,
                params.eventEmitter,
                params.market.marketToken,
                params.market.longToken,
                position.account,
                fees.longTokenFundingFeeAmount.toUint256()
            );
        }

        if (fees.shortTokenFundingFeeAmount > 0) {
            MarketUtils.incrementClaimableFundingAmount(
                params.dataStore,
                params.eventEmitter,
                params.market.marketToken,
                params.market.shortToken,
                position.account,
                fees.shortTokenFundingFeeAmount.toUint256()
            );
        }

        position.borrowingFactor = cache.nextPositionBorrowingFactor;
        position.increasedAtBlock = Chain.currentBlockNumber();

        params.positionStore.set(params.positionKey, params.order.account(), position);

        if (params.order.sizeDeltaUsd() > 0) {
            MarketUtils.applyDeltaToOpenInterest(
                params.dataStore,
                params.eventEmitter,
                position.market,
                position.collateralToken,
                position.isLong,
                params.order.sizeDeltaUsd().toInt256()
            );
            MarketUtils.applyDeltaToOpenInterestInTokens(
                params.dataStore,
                params.eventEmitter,
                position.market,
                position.collateralToken,
                position.isLong,
                cache.sizeDeltaInTokens.toInt256()
            );
            MarketUtils.validateReserve(params.dataStore, params.market, prices, params.order.isLong());
        }

        PositionUtils.validatePosition(
            params.dataStore,
            params.referralStorage,
            position,
            params.market,
            prices
        );

        params.eventEmitter.emitPositionIncrease(
            params.positionKey,
            position.account,
            position.market,
            position.collateralToken,
            position.isLong,
            cache.executionPrice,
            params.order.sizeDeltaUsd(),
            cache.collateralDeltaAmount
        );

        ReferralUtils.incrementAffiliateReward(
            params.dataStore,
            params.eventEmitter,
            position.market,
            position.collateralToken,
            fees.affiliate,
            position.account,
            fees.affiliateRewardAmount
        );

        if (fees.traderDiscountAmount > 0) {
            params.eventEmitter.emitTraderReferralDiscountApplied(position.account, position.collateralToken, fees.traderDiscountAmount);
        }
    }

    function processCollateral(
        IncreasePositionParams memory params,
        MarketUtils.MarketPrices memory prices,
        Position.Props memory position,
        int256 collateralDeltaAmount
    ) internal returns (int256, PositionPricingUtils.PositionFees memory) {
        Price.Props memory collateralTokenPrice = MarketUtils.getCachedTokenPrice(params.collateralToken, params.market, prices);

        PositionPricingUtils.PositionFees memory fees = PositionPricingUtils.getPositionFees(
            params.dataStore,
            params.referralStorage,
            position,
            collateralTokenPrice,
            params.market.longToken,
            params.market.shortToken,
            params.order.sizeDeltaUsd()
        );

        PricingUtils.transferFees(
            params.dataStore,
            params.feeReceiver,
            params.market.marketToken,
            position.collateralToken,
            fees.feeReceiverAmount,
            FeeUtils.POSITION_FEE
        );

        collateralDeltaAmount -= fees.totalNetCostAmount.toInt256();

        MarketUtils.applyDeltaToCollateralSum(
            params.dataStore,
            params.eventEmitter,
            params.order.market(),
            params.collateralToken,
            params.order.isLong(),
            collateralDeltaAmount
        );

        MarketUtils.applyDeltaToPoolAmount(
            params.dataStore,
            params.eventEmitter,
            params.market.marketToken,
            params.collateralToken,
            fees.feesForPool.toInt256()
        );

        params.eventEmitter.emitPositionFeesCollected(true, fees);

        return (collateralDeltaAmount, fees);
    }
}
