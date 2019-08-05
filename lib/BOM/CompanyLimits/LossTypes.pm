package BOM::CompanyLimits::LossTypes;

use strict;
use warnings;

use ExchangeRates::CurrencyConverter qw(convert_currency);

sub _convert_to_usd {
    my ($account_data, $amount) = @_;

    if ($account_data->{currency_code} ne 'USD') {
        $amount = convert_currency($amount, $account_data->{currency_code}, 'USD');
    }

    return $amount;
}

sub calc_realized_loss {
    my ($contract) = @_;
    my $bet_data = $contract->{bet_data};

    return _convert_to_usd($contract->{account_data}, $bet_data->{sell_price} - $bet_data->{buy_price});
}

sub calc_potential_loss {
    my ($contract) = @_;
    my $bet_data = $contract->{bet_data};

    return _convert_to_usd($contract->{account_data}, $bet_data->{payout_price} - $bet_data->{buy_price});
}

sub calc_turnover {
    my ($contract) = @_;

    return _convert_to_usd($contract->{account_data}, $contract->{bet_data}->{buy_price});
}

1;
