use strict;
use warnings;
use utf8;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use Brands;

my $c = BOM::Test::RPC::QueueClient->new();

my $method = 'active_symbols';
subtest "$method on binary_smarttrader" => sub {
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
    # the full list of active symbols is 83. But, smart trader only offers 63, excluding:
    # - cryptocurrenty
    # - jump indices
    # - crash/bomm indices
    # - stpRNG
    is(scalar @$result, 68, 'the default landing company is "svg", the number of result should be ok');
};

# unauthenticated call for `active_symbols` for landing company like `maltainvest` doesn't have an offering
my $landing_company_name = 'maltainvest';
subtest "active_symbols for $landing_company_name" => sub {
    # check the selected landing comapny doesn't have offerings
    my $landing_company = LandingCompany::Registry::get($landing_company_name);
    my $offering        = $landing_company->default_product_type;
    ok $offering, "offerings for maltainvest";

    my $params = {
        source   => 1,      # binary_smarttrader
        language => 'EN',
        args     => {
            active_symbols  => 'brief',
            landing_company => $landing_company_name,
        }};

    my $result = $c->call_ok($method, $params)->has_no_error->result;
    is scalar @$result, 0, 'zero symbols for binary_smarttrader';

    $params->{source} = 11780;                                                 # dervi_dtrader
    $result = $c->call_ok($method, $params)->has_no_error->result;
    is scalar @$result, 14, '14 major forex pairs';
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

subtest 'active_symbols for whitelisted apps' => sub {
    subtest 'deriv' => sub {
        my $deriv  = Brands->new(name => 'deriv');
        my $params = {
            language => 'EN',
            args     => {
                active_symbols => 'brief',
            }};
        my %expected_symbol_count = (
            11780 => 79,
            1408  => 0,
            16303 => 79,
            16929 => 79,
            19111 => 74,
            19112 => 74,
            22168 => 68,
            23789 => 49,
        );
        my $app = $deriv->whitelist_apps;
        foreach my $app_id (keys %$app) {
            $params->{source} = $app_id;
            my $result = $c->call_ok($method, $params)->has_no_system_error->result;
            is scalar @$result, $expected_symbol_count{$app_id}, 'symbol count expected for ' . $app->{$app_id}{name} . ' with id ' . $app_id
                if ref $result eq 'ARRAY';
        }
    };

    subtest 'binary' => sub {
        my $deriv  = Brands->new(name => 'binary');
        my $params = {
            language => 'EN',
            args     => {
                active_symbols => 'brief',
            }};
        my %expected_symbol_count = (
            1  => 68,
            10 => {
                normal       => 34,
                quiet_period => 21,
            },
            11    => 68,
            1169  => 68,
            14473 => 68,
            15284 => 68,
            15437 => 68,
            15438 => 68,
            15481 => 68,
            15488 => {
                normal       => 34,
                quiet_period => 21
            });
        my $o = LandingCompany::Registry::get('svg')->basic_offerings({
            loaded_revision => 1,
            action          => 'buy'
        });
        my $app = $deriv->whitelist_apps;
        foreach my $app_id (keys %$app) {
            $params->{source} = $app_id;
            my $result = $c->call_ok($method, $params)->has_no_system_error->result;
            if ($app_id == 10 or $app_id == 15488) {
                is scalar @$result, $expected_symbol_count{$app_id}{($o->is_quiet_period ? 'quiet_period' : 'normal')},
                    'symbol count expected for ' . $app->{$app_id}{name}
                    if ref $result eq 'ARRAY';
            } else {
                is scalar @$result, $expected_symbol_count{$app_id}, 'symbol count expected for ' . $app->{$app_id}{name} if ref $result eq 'ARRAY';
            }
        }
    };
};

done_testing();

