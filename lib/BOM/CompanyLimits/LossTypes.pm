package BOM::CompanyLimits::LossTypes;

use strict;
use warnings;

use ExchangeRates::CurrencyConverter;

sub calc_realized_loss {
    my ($bet_data, $currency) = @_;

    return ExchangeRates::CurrencyConverter::in_usd($bet_data->{sell_price} - $bet_data->{buy_price}, $currency);
}

sub calc_potential_loss {
    my ($bet_data, $currency) = @_;

    return ExchangeRates::CurrencyConverter::in_usd($bet_data->{payout_price} - $bet_data->{buy_price}, $currency);
}

sub calc_turnover {
    my ($bet_data, $currency) = @_;

    return ExchangeRates::CurrencyConverter::in_usd($bet_data->{buy_price}, $currency);
}

1;
