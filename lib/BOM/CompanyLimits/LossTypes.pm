package BOM::CompanyLimits::LossTypes;

use strict;
use warnings;

use ExchangeRates::CurrencyConverter;

sub get_calc_loss_func {
    my ($loss_type) = @_;

    if ($loss_type eq 'potential_loss') {
        return \&calc_potential_loss;
    } elsif ($loss_type eq 'realized_loss') {
        return \&calc_realized_loss;
    } elsif ($loss_type eq 'turnover') {
        return \&calc_turnover;
    }

    die "Cannot find loss calculation function for loss type: $loss_type";
}

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
