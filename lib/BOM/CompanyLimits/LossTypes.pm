package BOM::CompanyLimits::LossTypes;

use strict;
use warnings;

use ExchangeRates::CurrencyConverter;

sub calc_realized_loss {
    my ($contract) = @_;
    my $bet_data = $contract->{bet_data};

    return ExchangeRates::CurrencyConverter::in_usd($bet_data->{sell_price} - $bet_data->{buy_price}, $contract->{account_data}->{currency_code});
}

sub calc_potential_loss {
    my ($contract) = @_;
    my $bet_data = $contract->{bet_data};

    return ExchangeRates::CurrencyConverter::in_usd($bet_data->{payout_price} - $bet_data->{buy_price}, $contract->{account_data}->{currency_code});
}

sub calc_turnover {
    my ($contract) = @_;

    return ExchangeRates::CurrencyConverter::in_usd($contract->{bet_data}->{buy_price}, $contract->{account_data}->{currency_code});
}

1;
