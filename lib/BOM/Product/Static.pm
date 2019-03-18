package BOM::Product::Static;

use strict;
use warnings;

use Exporter qw( import );
our @EXPORT_OK = qw(get_error_mapping get_generic_mapping);

=head1 NAME

BOM::Product::Static

=head1 SYNOPSIS

=head1 DESCRIPTION

This class provides static configurations like error mapping and generic message mapping

=cut

my $config = {
    errors => {
        # kept camel case because RPC/WS/Pricing follow this convention
        # it will be consistent in case in future we want to send
        # these as error codes to RPC/Pricing
        InvalidPayoutCurrency         => 'Invalid payout currency',
        InvalidInputAsset             => 'Trading is not offered for this asset.',
        InvalidTickExpiry             => 'Invalid duration (tick) for contract type ([_1]).',
        InvalidBarrierMixedBarrier    => 'Invalid barrier (Contract can have only one type of barrier).',
        InvalidBarrierSingle          => 'Invalid barrier (Single barrier input is expected).',
        InvalidBarrierDouble          => 'Invalid barrier (Double barrier input is expected).',
        InvalidBarrierDifferentType   => 'Invalid barrier (Barrier type must be the same for double-barrier contracts).',
        MissingRequiredUnderlying     => 'Missing required contract parameters (underlying).',
        MissingRequiredExpiry         => 'Missing required contract parameters (date_expiry or duration).',
        MissingRequiredStart          => 'Missing required contract parameters (date_start).',
        MissingRequiredBetType        => 'Missing required contract parameters (bet_type).',
        MissingRequiredCurrency       => 'Missing required contract parameters (currency).',
        MissingRequiredDigit          => 'Missing required contract parameters (last digit prediction for digit contracts).',
        MissingRequiredMultiplier     => 'Missing required contract parameters (multiplier).',
        MissingRequiredSelectedTick   => 'Missing required contract parameters (selected tick).',
        MinimumMultiplier             => 'Minimum multiplier of',
        MultiplierDecimalPlace        => 'Only 3 decimal places are allowed.',
        AlreadyExpired                => 'This contract has already expired.',
        BarrierNotInRange             => 'Barrier is not an integer in range of [_1] to [_2].',
        BarrierOutOfRange             => 'Barrier is out of acceptable range.',
        InvalidVolatility             => 'We could not process this contract at this time.',
        CannotValidateContract        => 'Cannot validate contract.',
        ContractAlreadySold           => 'This contract has been sold.',
        ContractExpiryNotAllowed      => 'Contract may not expire between [_1] and [_2].',
        CrossMarketIntraday           => 'Intraday contracts may not cross market open.',
        DigitOutOfRange               => 'Digit must be in the range of [_1] to [_2].',
        EntryTickMissing              => 'Waiting for entry tick.',
        ForwardStartTime              => 'Start time on forward-starting contracts must be more than 5 minutes from now.',
        FutureStartTime               => 'Start time is in the future.',
        IncorrectPayoutDecimals       => 'Payout can not have more than [_1] decimal places.',
        IncorrectStakeDecimals        => 'Stake can not have more than [_1] decimal places.',
        IntegerBarrierRequired        => 'Barrier must be an integer.',
        IntegerSelectedTickRequired   => 'Selected tick must be an integer.',
        InvalidBarrier                => 'Invalid barrier.',
        InvalidBarrierUndef           => 'Invalid barrier.',
        InvalidBarrierForSpot         => 'Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.',
        InvalidBarrierRange           => 'Barriers must be on either side of the spot.',
        InvalidContractType           => 'Invalid contract type.',
        InvalidExpiryTime             => 'Invalid expiry time.',
        InvalidHighBarrier            => 'High barrier must be higher than low barrier.',
        InvalidHighLowBarrrierRange   => 'High barrier is out of acceptable range. Please adjust the high barrier.',
        InvalidInput                  => '[_1] is not a valid input for contract type [_2].',
        InvalidLowBarrrierRange       => 'Low barrier is out of acceptable range. Please adjust the low barrier.',
        InvalidNonBinaryPrice         => 'Contract price cannot be zero.',
        InvalidStake                  => 'Invalid stake/payout.',
        MarketIsClosed                => 'This market is presently closed.',
        MarketIsClosedTryVolatility   => 'This market is presently closed. Try out the Volatility Indices which are always open.',
        MarketNotOpen                 => 'The market must be open at the start time.',
        MarketNotOpenTryVolatility    => 'The market must be open at the start time. Try out the Volatility Indices which are always open.',
        MarketPricePayoutClose        => 'Contract market price is too close to final payout.',
        MissingDividendMarketData     => 'Trading is suspended due to missing market (dividend) data.',
        MissingMarketData             => 'Trading is suspended due to missing market data.',
        MissingSpotMarketData         => 'Trading is suspended due to missing market (spot too far) data.',
        MissingTickMarketData         => 'Trading is suspended due to missing market (tick) data.',
        MissingVolatilityMarketData   => 'Trading is suspended due to missing market (volatility) data.',
        NeedAbsoluteBarrier           => 'Contracts more than 24 hours in duration would need an absolute barrier.',
        NegativeContractBarrier       => 'Contract barrier must be positive.',
        NoReturn                      => 'This contract offers no return.',
        NonDeterminedBarriers         => 'Barriers could not be determined.',
        OldMarketData                 => 'Trading is suspended due to missing market (old) data.',
        OutdatedVolatilityData        => 'Trading is suspended due to missing market (out-of-date volatility) data.',
        PastExpiryTime                => 'Expiry time cannot be in the past.',
        PastStartTime                 => 'Start time is in the past.',
        PredefinedNeedAbsoluteBarrier => 'Contracts with predefined barrier would need an absolute barrier.',
        RefundBuyForMissingData       => 'The buy price of this contract will be refunded due to missing market data.',
        ResaleNotOffered              => 'Resale of this contract is not offered.',
        ResaleNotOfferedHolidays      => 'Resale of this contract is not offered due to market holidays during contract period.',
        ResetBarrierError             => 'Non atm barrier is not allowed for reset contract.',
        ResetFixedExpiryError         => 'Fixed expiry for reset contract is not allowed.',
        SameBarriersNotAllowed        => 'High and low barriers must be different.',
        SameExpiryStartTime           => 'Expiry time cannot be equal to start time.',
        SameTradingDayExpiry          => 'Contracts on this market with a duration of under 24 hours must expire on the same trading day.',
        SelectedTickNumberLimits      => 'Number of ticks must be between [_1] and [_2].',
        SettlementError               => 'An error occurred during contract settlement.',
        PayoutLimitExceeded           => 'Maximum payout allowed is [_1].',
        StakeLimits                   => 'Minimum stake of [_1] and maximum payout of [_2]. Current stake is [_3].',
        PayoutLimits                  => 'Minimum stake of [_1] and maximum payout of [_2]. Current payout is [_3].',
        TicksNumberLimits             => 'Number of ticks must be between [_1] and [_2].',
        TooManyHolidays               => 'Too many market holidays during the contract period.',
        TradeTemporarilyUnavailable   => 'This trade is temporarily unavailable.',
        TradingDayEndExpiry           => 'Contracts on this market with a duration of more than 24 hours must expire at the end of a trading day.',
        TradingDayExpiry              => 'The contract must expire on a trading day.',
        TradingDurationNotAllowed     => 'Trading is not offered for this duration.',
        TradingHoursExpiry            => 'Contract must expire during trading hours.',
        TradingNotAvailable           => 'Trading is not available from [_1] to [_2].',
        TradingSuspendedSpecificHours => 'Trading on forex contracts with duration less than 5 hours is not available from [_1] to [_2]',
        WaitForContractSettlement     => 'Please wait for contract settlement. The final settlement price may differ from the indicative price.',
        WrongAmountTypeOne            => 'Basis must be [_1] for this contract.',
        WrongAmountTypeTwo            => 'Basis can either be [_1] or [_2] for this contract.',
        ZeroAbsoluteBarrier           => 'Absolute barrier cannot be zero.',
        CountrySpecificError          => '[_1] is not allowed for residence of [_2].',
        MissingTradingPeriodStart     => 'trading_period_start must be supplied for multi barrier contracts.',
    },
    generic => {
        # use it audit details
        start_time     => 'Start Time',
        end_time       => 'End Time',
        exit_spot      => 'Exit Spot',
        entry_spot_cap => 'Entry Spot',
        closing_spot   => 'Closing Spot',
        highest_spot   => 'Highest Spot',
        lowest_spot    => 'Lowest Spot',
        time_and_spot  => '[_1] and [_2]',
        # sub-categories in trading page
        risefall       => 'Rise/Fall',
        higherlower    => 'Higher/Lower',
        inout          => 'In/Out',
        matchesdiffers => 'Matches/Differs',
        evenodd        => 'Even/Odd',
        overunder      => 'Over/Under',
        # OHLC
        high  => 'High',
        low   => 'Low',
        close => 'Close',
        # limits page
        atm            => 'ATM',
        nonatm         => 'Non-ATM',
        uptosevendays  => 'Duration up to 7 days',
        abovesevendays => 'Duration above 7 days',
        # trading times page
        closeatnine => 'Closes early (at 21:00)',
        closeatsix  => 'Closes early (at 18:00)',
        newyear     => 'New Year\'s Day',
        christmas   => 'Christmas Day',
        fridays     => 'Fridays',
        today       => 'today',
        todayfriday => 'today, Fridays',

        # statement
        sell          => 'Sell',
        buy           => 'Buy',
        virtualcredit => 'Virtual money credit to account',
        # etc
        payout       => 'Payoff',
        serverdown   => 'There was a problem accessing the server.',
        purchasedown => 'There was a problem accessing the server during purchase.',
    },
};

=head2 get_error_mapping

Return error mapping for all the error message related to Contract

=cut

sub get_error_mapping {
    return $config->{errors};
}

=head2 get_generic_mapping

Return mapping for generic text used for contracts

=cut

sub get_generic_mapping {
    return $config->{generic};
}

1;
