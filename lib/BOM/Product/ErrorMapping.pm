package BOM::Product::ErrorMapping;

use strict;
use warnings;

=head1 NAME

BOM::Product::ErrorMapping

=head1 SYNOPSIS

=head1 DESCRIPTION

This class maps error code to error message for contract

=cut

my $config = {
    CannotProcessContract             => 'We could not process this contract at this time.',
    MarketPricePayoutClose            => 'Contract market price is too close to final payout.',
    CrossMarketIntraday               => 'Intraday contracts may not cross market open.',
    CannotValidateContract            => 'Cannot validate contract.',
    DigitOutOfRange                   => 'Digit must be in the range of [_1] to [_2].',
    NegativeContractBarrier           => 'Contract barrier must be positive.',
    BarrierNotInRange                 => 'Barrier is not an integer between [_1] to [_2].',
    ContractAlreadySold               => 'This contract has been sold.',
    WaitForContractSettlement         => 'Please wait for contract settlement. The final settlement price may differ from the indicative price.',
    ContractAffectedByCorporateAction => 'This contract is affected by corporate action.',
    TradeTemporarilyUnavailable       => 'This trade is temporarily unavailable.',
    StakePayoutLimits                 => 'Minimum stake of [_1] and maximum payout of [_2].',
    IncorrectPayoutDecimals           => 'Payout may not have more than two decimal places.',
    NoReturn                          => 'This contract offers no return.',
    NeedAbsoluteBarrier               => 'Contracts more than 24 hours in duration would need an absolute barrier.',
    SameExpiryStartTime               => 'Expiry time cannot be equal to start time.',
    PastExpiryTime                    => 'Expiry time cannot be in the past.',
    PastStartTime                     => 'Start time is in the past.',
    FutureStartTime                   => 'Start time is in the future.',
    ForwardStartTime                  => 'Start time on forward-starting contracts must be more than 5 minutes from now.',
    AlreadyExpired                    => 'Contract has already expired.',
    TradingDayEndExpiry               => 'Contracts on this market with a duration of more than 24 hours must expire at the end of a trading day.',
    MarketNotOpenAtStart              => 'The market must be open at the start time. Try out the Volatility Indices which are always open.',
    MarketIsClosed                    => 'This market is presently closed. Try out the Volatility Indices which are always open.',
    TradingDayExpiry                  => 'The contract must expire on a trading day.',
    TradingHoursExpiry                => 'Contract must expire during trading hours.',
    SameTradingDayExpiry              => 'Contracts on this market with a duration of under 24 hours must expire on the same trading day.',
    ResaleNotOffered                  => 'Resale of this contract is not offered.',
    TicksNumberLimits                 => 'Number of ticks must be between [_1] and [_2].',
    TradingSuspended                  => 'Trading is currently suspended due to configuration update.',
    SettlementError                   => 'System problems prevent proper settlement at this time.',
    InvalidStake                      => 'Invalid stake.',
    InvalidBarrier                    => 'Invalid barrier.',
    IntegerBarrierRequired            => 'Barrier must be an integer.',
    InvalidHighBarrier                => 'High barrier must be higher than low barrier.',
    SameBarriers                      => 'High and low barriers must be different.',
    NonDeterminedBarriers             => 'Proper barriers could not be determined.',
    InvalidBarrierRange               => 'Barriers must be on either side of the spot.',
    InvalidBarrierForSpot             => 'Barrier must be at least [plural,_1,%d pip,%d pips] away from the spot.',
    InvalidExpiryTime                 => 'Invalid expiry time.',
    NeedAbsoluteBarrier               => 'Contracts with predefined barrier would need an absolute barrier',
    BarrierNotInRange                 => 'Barrier is out of acceptable range.',
    ZeroBarrier                       => 'Absolute barrier cannot be zero.',
    TradingNotAvailable               => 'Trading is not available from [_1] to [_2].',
    MissingDividendMarketData         => 'Trading on this market is suspended due to missing market (dividend) data.',
    MissingTickMarketData             => 'Trading on this market is suspended due to missing market (tick) data.',
    MissingVolatilityMarketData       => 'Trading is suspended due to missing market (volatility) data.',
    MissingSpotMarketData             => 'Trading is suspended due to missing market (spot too far) data.',
    OutdatedVolatilityData            => 'Trading is suspended due to missing market (out-of-date volatility) data.',
    OldMarketData                     => 'Trading on this market is suspended due to missing market (old) data.',
};

=head2 get_error_mapping

Return error mapping for all the error message related to Contract

=cut

sub get_error_mapping {
    return $config;
}

1;
