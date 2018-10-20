use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;

use BOM::Test::RPC::Client;
use BOM::Config::CurrencyConfig;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
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
    my ($sh) = grep { $_->{text} eq 'Shanghai' } @$result;
    is_deeply(
        $sh,
        {
            'value' => '31',
            'text'  => "Shanghai",
        },
        'Shanghai is correct'
    );
};

subtest 'currencies_config.transfer_between_accounts' => sub {
    my $result = $c->call_ok(
        'website_status',
        {
            language => 'EN',
            args     => {website_status => 1}})->has_no_system_error->has_no_error->result;

    my @all_currencies  = keys %{LandingCompany::Registry::get('costarica')->legal_allowed_currencies};
    my $currency_config = BOM::Config::CurrencyConfig::transfer_between_accounts_limits();

    cmp_ok(
        $currency_config->{$_}->{min},
        '==',
        $result->{currencies_config}->{$_}->{limits}->{transfer_between_accounts}->{min},
        "Transfer between account minimum is correct for $_"
    ) for @all_currencies;

};

done_testing();
