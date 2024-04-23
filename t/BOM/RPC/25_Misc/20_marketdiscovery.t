use strict;
use warnings;
use utf8;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase   qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase   qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Brands;

my $c = BOM::Test::RPC::QueueClient->new();

subtest "active_symbols - translation" => sub {
    # just test a few languages :)
    my $params = {
        args => {
            active_symbols => 'brief',
        }};

    my %test_cases = (
        ES => {
            market_display_name    => 'Forex',
            submarket_display_name => 'Pares menores',
        },
        FR => {
            market_display_name    => 'Forex',
            submarket_display_name => 'Paires mineures',
        },
        IT => {
            market_display_name    => 'Devisenhandel',
            submarket_display_name => 'Coppie minori',
        },
    );

    foreach my $language (keys %test_cases) {
        $params->{language} = $language;
        my $result = $c->call_ok('active_symbols', $params)->has_no_system_error->result;
        my ($audcad) = grep { $_->{symbol} eq 'frxAUDCAD' } $result->@*;
        is $audcad->{market_display_name},    $test_cases{$language}{market_display_name};
        is $audcad->{submarket_display_name}, $test_cases{$language}{submarket_display_name};
    }
};

subtest "active_symbols - response keys" => sub {
    my $params = {
        language => 'EN',
        args     => {
            active_symbols => 'full',
        }};
    my $result        = $c->call_ok('active_symbols', $params)->has_no_system_error->result;
    my $expected_keys = [
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting exchange_name delay_amount quoted_currency_symbol intraday_interval_minutes spot spot_time spot_age subgroup subgroup_display_name display_order spot_percentage_change)
    ];
    cmp_bag([keys $result->[0]->%*], $expected_keys, 'response keys matched');
};

subtest "active_symbols - contract type" => sub {
    my $params = {
        language => 'EN',
        args     => {
            active_symbols => 'full',
            contract_type  => ["RANGE"]}};
    my $result        = $c->call_ok('active_symbols', $params)->has_no_system_error->result;
    my $expected_keys = [
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting exchange_name delay_amount quoted_currency_symbol intraday_interval_minutes spot spot_time spot_age subgroup subgroup_display_name display_order spot_percentage_change)
    ];
    cmp_bag([keys $result->[0]->%*], $expected_keys, 'response keys matched');
};

done_testing();

