use strict;
use warnings;
use utf8;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use LandingCompany::Registry;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

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

    my ($indices) = grep { $_->{symbol} eq 'AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');
    delete $params->{country_code};
    $params->{args}{active_symbols} = 'full';
    push @$expected_keys, qw(exchange_name delay_amount quoted_currency_symbol intraday_interval_minutes spot spot_time spot_age);
    $result = $c->call_ok($method, $params)->has_no_system_error->result;
    ($indices) = grep { $_->{symbol} eq 'AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');
    is($indices->{market_display_name},    'Indices', 'the market_display_name is translated');
    is($indices->{submarket_display_name}, 'Europe',  'the submarket_display_name is translated');
    is(scalar @$result,                    77,        'the default landing company is "svg", the number of result should be ok');
};

# unauthenticated call for `active_symbols` for landing company like `maltainvest` doesn't have an offering
my $landing_company_name = 'maltainvest';
subtest "active_symbols_for_" => sub {
    # check the selected landing comapny doesn't have offerings
    my $landing_company = LandingCompany::Registry::get($landing_company_name);
    my $offering        = $landing_company->default_product_type;
    is $offering, undef, "The selected landing company doesn't have an offering";

    my $params = {
        language => 'EN',
        args     => {
            active_symbols  => 'brief',
            landing_company => $landing_company_name,
        }};

    is_deeply $c->call_ok($method, $params)->has_no_error->result, [], 'No active symbols for companies without offerings';
};

done_testing();

