package BOM::Product::Static;

use strict;
use warnings;

use Exporter qw( import );
our @EXPORT_OK = qw(get_error_mapping get_longcodes);

=head1 NAME

BOM::Product::Static

=head1 SYNOPSIS

=head1 DESCRIPTION

This class provides static configurations like error mapping, longcodes mapping

=cut

my $config = {
    errors => {
        # kept camel case because RPC/WS/Pricing follow this convention
        # it will be consistent in case in future we want to send
        # these as error codes to RPC/Pricing
        InvalidTickExpiry             => 'Invalid duration (tick) for contract type ([_1]).',
        InvalidBarrierWithReason      => 'Invalid barrier ([_1]).',
        MissingRequiredInput          => 'Missing required contract parameters ([_1]).',
        AlreadyExpired                => 'This contract has already expired.',
        BarrierNotInRange             => 'Barrier is not an integer in range of [_1] to [_2].',
        BarrierOutOfRange             => 'Barrier is out of acceptable range.',
        BinaryIcoTokenLimits          => 'Number of token placed must be between [_1] and [_2].',
        CannotProcessContract         => 'We could not process this contract at this time.',
        CannotValidateContract        => 'Cannot validate contract.',
        ContractAlreadySold           => 'This contract has been sold.',
        ContractExpiryNotAllowed      => 'Contract may not expire between [_1] and [_2].',
        CrossMarketIntraday           => 'Intraday contracts may not cross market open.',
        DigitOutOfRange               => 'Digit must be in the range of [_1] to [_2].',
        EntryTickMissing              => 'Waiting for entry tick.',
        ForwardStartTime              => 'Start time on forward-starting contracts must be more than 5 minutes from now.',
        FutureStartTime               => 'Start time is in the future.',
        IncorrectPayoutDecimals       => 'Payout can not have more than [_1] decimal places.',
        IntegerBarrierRequired        => 'Barrier must be an integer.',
        InvalidBarrier                => 'Invalid barrier.',
        InvalidBarrierForSpot         => 'Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.',
        InvalidBarrierRange           => 'Barriers must be on either side of the spot.',
        InvalidExpiryTime             => 'Invalid expiry time.',
        InvalidHighBarrier            => 'High barrier must be higher than low barrier.',
        InvalidHighLowBarrrierRange   => 'High barrier is out of acceptable range. Please adjust the high barrier.',
        InvalidLowBarrrierRange       => 'Low barrier is out of acceptable range. Please adjust the low barrier.',
        InvalidLookbacksPrice         => 'Lookbacks price cannot be zero.',
        InvalidStake                  => 'Invalid stake/payout.',
        InvalidBinaryIcoBidPrice      => 'Sorry, but your bid is too low. The minimum bid allowed is USD1 (or its equivalent in another currency).',
        IcoClosed                     => 'The ICO is now closed.',
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
        SameBarriersNotAllowed        => 'High and low barriers must be different.',
        SameExpiryStartTime           => 'Expiry time cannot be equal to start time.',
        SameTradingDayExpiry          => 'Contracts on this market with a duration of under 24 hours must expire on the same trading day.',
        SettlementError               => 'An error occurred during contract settlement.',
        StakePayoutLimits             => 'Minimum stake of [_1] and maximum payout of [_2].',
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
        ZeroAbsoluteBarrier           => 'Absolute barrier cannot be zero.',
    },
    longcodes => {
        asiand_tick                 => 'Win payout if the last tick of [_3] is strictly lower than the average of the [plural,_5,%d tick,%d ticks].',
        asianu_tick                 => 'Win payout if the last tick of [_3] is strictly higher than the average of the [plural,_5,%d tick,%d ticks].',
        call_daily                  => 'Win payout if [_3] is strictly higher than [_6] at [_5].',
        call_intraday               => 'Win payout if [_3] is strictly higher than [_6] at [_5] after [_4].',
        call_intraday_fixed_expiry  => 'Win payout if [_3] is strictly higher than [_6] at [_5].',
        call_tick                   => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is strictly higher than [_6].',
        calle_daily                 => 'Win payout if [_3] is higher than or equal to [_6] at [_5].',
        calle_intraday              => 'Win payout if [_3] is higher than or equal to [_6] at [_5] after [_4].',
        calle_intraday_fixed_expiry => 'Win payout if [_3] is higher than or equal to [_6] at [_5].',
        calle_tick                  => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is higher than or equal to [_6].',
        digitdiff_tick              => 'Win payout if the last digit of [_3] is not [_6] after [plural,_5,%d tick,%d ticks].',
        digiteven_tick              => 'Win payout if the last digit of [_3] is even after [_5] ticks.',
        digitmatch_tick             => 'Win payout if the last digit of [_3] is [_6] after [plural,_5,%d tick,%d ticks].',
        digitodd_tick               => 'Win payout if the last digit of [_3] is odd after [_5] ticks.',
        digitover_tick              => 'Win payout if the last digit of [_3] is strictly higher than [_6] after [_5] ticks.',
        digitunder_tick             => 'Win payout if the last digit of [_3] is strictly lower than [_6] after [_5] ticks.',
        expirymiss_daily            => 'Win payout if [_3] ends outside [_7] to [_6] at [_5].',
        expirymiss_intraday         => 'Win payout if [_3] ends outside [_7] to [_6] at [_5] after [_4].',
        expirymiss_intraday_fixed_expiry   => 'Win payout if [_3] ends outside [_7] to [_6] at [_5].',
        expirymisse_daily                  => 'Win payout if [_3] ends on or outside [_7] to [_6] at [_5].',
        expirymisse_intraday               => 'Win payout if [_3] ends on or outside [_7] to [_6] at [_5] after [_4].',
        expirymisse_intraday_fixed_expiry  => 'Win payout if [_3] ends on or outside [_7] to [_6] at [_5].',
        expiryrange_daily                  => 'Win payout if [_3] ends strictly between [_7] to [_6] at [_5].',
        expiryrange_intraday               => 'Win payout if [_3] ends strictly between [_7] to [_6] at [_5] after [_4].',
        expiryrange_intraday_fixed_expiry  => 'Win payout if [_3] ends strictly between [_7] to [_6] at [_5].',
        expiryrangee_daily                 => 'Win payout if [_3] ends on or between [_7] to [_6] at [_5].',
        expiryrangee_intraday              => 'Win payout if [_3] ends on or between [_7] to [_6] at [_5] after [_4].',
        expiryrangee_intraday_fixed_expiry => 'Win payout if [_3] ends on or between [_7] to [_6] at [_5].',
        legacy_contract                    => 'Legacy contract. No further information is available.',
        notouch_daily                      => 'Win payout if [_3] does not touch [_6] through [_5].',
        notouch_intraday                   => 'Win payout if [_3] does not touch [_6] through [_5] after [_4].',
        notouch_intraday_fixed_expiry      => 'Win payout if [_3] does not touch [_6] through [_5].',
        onetouch_daily                     => 'Win payout if [_3] touches [_6] through [_5].',
        onetouch_intraday                  => 'Win payout if [_3] touches [_6] through [_5] after [_4].',
        onetouch_intraday_fixed_expiry     => 'Win payout if [_3] touches [_6] through [_5].',
        put_daily                          => 'Win payout if [_3] is strictly lower than [_6] at [_5].',
        put_intraday                       => 'Win payout if [_3] is strictly lower than [_6] at [_5] after [_4].',
        put_intraday_fixed_expiry          => 'Win payout if [_3] is strictly lower than [_6] at [_5].',
        put_tick                           => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is strictly lower than [_6].',
        pute_daily                         => 'Win payout if [_3] is lower than or equal to [_6] at [_5].',
        pute_intraday                      => 'Win payout if [_3] is lower than or equal to [_6] at [_5] after [_4].',
        pute_intraday_fixed_expiry         => 'Win payout if [_3] is lower than or equal to [_6] at [_5].',
        pute_tick                          => 'Win payout if [_3] after [plural,_5,%d tick,%d ticks] is lower than or equal to [_6].',
        range_daily                        => 'Win payout if [_3] stays between [_7] to [_6] through [_5].',
        range_intraday                     => 'Win payout if [_3] stays between [_7] and [_6] through [_5] after [_4].',
        range_intraday_fixed_expiry        => 'Win payout if [_3] stays between [_7] to [_6] through [_5].',
        upordown_daily                     => 'Win payout if [_3] goes outside [_7] to [_6] through [_5].',
        upordown_intraday                  => 'Win payout if [_3] goes outside [_7] and [_6] through [_5] after [_4].',
        upordown_intraday_fixed_expiry     => 'Win payout if [_3] goes outside [_7] to [_6] through [_5].',
    },
    generic => {
        # params passed to longcode that needs translation
        close_on                => 'close on [_1]',
        contract_start_time     => 'contract start time',
        entry_spot              => 'entry spot',
        entry_spot_minus        => 'entry spot minus [_1]',
        entry_spot_minus_plural => 'entry spot minus [plural,_1,%d pip, %d pips]',
        entry_spot_plus         => 'entry spot plus [_1]',
        entry_spot_plus_plural  => 'entry spot plus [plural,_1,%d pip, %d pips]',
        first_tick              => 'first tick',
        # use it audit details
        start_time     => 'Start Time',
        end_time       => 'End Time',
        exit_spot      => 'Exit Spot',
        entry_spot_cap => 'Entry Spot',
        closing_spot   => 'Closing Spot',
        time_and_spot  => '[_1] and [_2]',
    },
};

=head2 get_error_mapping

Return error mapping for all the error message related to Contract

=cut

sub get_error_mapping {
    return $config->{errors};
}

=head2 get_longcodes

Return longcodes for all the contract types

=cut

sub get_longcodes {
    return $config->{longcodes};
}

=head2 get_generic_mapping

Return mapping for generic text used for contracts

=cut

sub get_generic_mapping {
    return $config->{generic};
}

1;
