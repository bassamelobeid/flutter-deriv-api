use strict;
use warnings;
use utf8;
use BOM::Test::RPC::QueueClient;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;

my $c = BOM::Test::RPC::QueueClient->new();

my $method = 'active_symbols';
subtest $method => sub {
    my $params = {
        language => 'EN',
        args     => {
            active_symbols => 'brief',
        }};

    my $result = $c->call_ok($method, $params)->has_no_system_error->result;
    my $expected_keys =
        [
        qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended allow_forward_starting)
        ];

    my ($indices) = grep { $_->{symbol} eq 'OTC_AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');
    delete $params->{country_code};
    $params->{args}{active_symbols} = 'full';
    push @$expected_keys, qw(exchange_name delay_amount quoted_currency_symbol intraday_interval_minutes spot spot_time spot_age);
    $result = $c->call_ok($method, $params)->has_no_system_error->result;
    ($indices) = grep { $_->{symbol} eq 'OTC_AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');
    is($indices->{market_display_name},    'Stock Indices', 'the market_display_name is translated');
    is($indices->{submarket_display_name}, 'Europe',        'the submarket_display_name is translated');
    is(scalar @$result,                    63,              'the default landing company is "svg", the number of result should be ok');
};

# unauthenticated call for `active_symbols` for landing company like `maltainvest` doesn't have an offering
my $landing_company_name = 'maltainvest';
subtest "active_symbols_for_" => sub {
    # check the selected landing comapny doesn't have offerings
    my $landing_company = LandingCompany::Registry::get($landing_company_name);
    my $offering        = $landing_company->default_product_type;
    ok $offering, "offerings for maltainvest";

    my $params = {
        language => 'EN',
        args     => {
            active_symbols  => 'brief',
            landing_company => $landing_company_name,
        }};

    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is scalar @$result, 14, '14 pairs';
};

subtest 'active_symbols for suspend_buy' => sub {
    my $params = {
        language => 'EN',
        args     => {
            active_symbols => 'brief',
        }};

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());
    my $prev_market_suspend_buy = $app_config->quants->markets->suspend_buy;
    note('setting app_config->quants->markets->suspend_buy to [\'forex\']');
    $app_config->set({'quants.markets.suspend_buy' => ['forex']});
    my $result = $c->call_ok($method, $params)->has_no_system_error->result;
    ok(!grep { $_->{market} eq 'forex' } @$result);
    note('resetting app_config->quants->markets->suspend_buy');
    $app_config->set({'quants.markets.suspend_buy' => $prev_market_suspend_buy});

    my $prev_underlying_suspend_buy = $app_config->quants->underlyings->suspend_buy;
    note('setting app_config->quants->underlyings->suspend_buy to [\'frxUSDJPY\']');
    $app_config->set({'quants.underlyings.suspend_buy' => ['frxUSDJPY']});
    $result = $c->call_ok($method, $params)->has_no_system_error->result;
    ok !grep { $_->{symbol} eq 'frxUSDJPY' } @$result;
    note('resetting app_config->quants->underlyings->suspend_buy');
    $app_config->set({'quants.underlyings.suspend_buy' => $prev_underlying_suspend_buy});
};

done_testing();

