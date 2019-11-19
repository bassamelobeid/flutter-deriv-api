use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use BOM::Test::RPC::Client;
use BOM::Config::CurrencyConfig;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Format::Util::Numbers qw/financialrounding/;

populate_exchange_rates();

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);
subtest 'residence_list' => sub {
    my $result = $c->call_ok('residence_list', {language => 'EN'})->has_no_system_error->result;
    my ($cn) = grep { $_->{value} eq 'cn' } @$result;
    is_deeply(
        $cn,
        {
            'value'     => 'cn',
            'text'      => "China",
            'phone_idd' => '86'
        },
        'cn is correct'
    );
};

subtest 'states_list' => sub {
    my $result = $c->call_ok(
        'states_list',
        {
            language => 'EN',
            args     => {states_list => 'cn'}})->has_no_system_error->result;
    my ($sh) = grep { $_->{text} eq 'Shanghai Shi' } @$result;
    is_deeply(
        $sh,
        {
            'value' => 'SH',
            'text'  => "Shanghai Shi",
        },
        'Shanghai Shi is correct'
    );
};

subtest 'currencies_config.transfer_between_accounts' => sub {

    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    my @all_currencies  = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};
    my $currency_limits = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();
    my $currency_fees   = BOM::Config::CurrencyConfig::transfer_between_accounts_fees();

    is(
        $currency_limits->{$_}->{min},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits}->{min},
        "Transfer between account minimum is correct for $_"
    ) for @all_currencies;

    is(
        $currency_limits->{$_}->{max},
        $result->{currencies_config}->{$_}->{transfer_between_accounts}->{limits}->{max},
        "Transfer between account maximum is correct for $_"
    ) for @all_currencies;

    for my $currency (@all_currencies) {
        cmp_ok(
            $currency_fees->{$currency}->{$_} // -1,
            '==',
            $result->{currencies_config}->{$currency}->{transfer_between_accounts}->{fees}->{$_} // -1,
            "Transfer between account fee is correct for ${currency}_$_"
        ) for @all_currencies;
    }

};

subtest 'crypto_config' => sub {

    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    my @all_currencies = keys %{LandingCompany::Registry::get('svg')->legal_allowed_currencies};
    my @currency       = map {
        if (LandingCompany::Registry::get_currency_type($_) eq 'crypto') { $_ }
    } @all_currencies;
    my @crypto_currency = grep { $_ ne '' } @currency;

    cmp_ok(
        0 + financialrounding(
            'amount', $_, ExchangeRates::CurrencyConverter::convert_currency(BOM::Config::crypto()->{$_}->{'withdrawal'}->{min_usd}, 'USD', $_)
        ),
        '==',
        $result->{crypto_config}->{$_}->{minimum_withdrawal},
        "API:website_status:crypto_config=> Minimum withdrawal in USD is correct for $_"
    ) for @crypto_currency;

};

done_testing();
