use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::SessionCookie;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $method = 'trading_times';
subtest $method => sub {
    my $params = {language => 'ZH_CN', 'args'=> {'trading_times' =>'2016-03-16'}};
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    ok($result->{markets}[0]{submarkets}, 'have sub markets key');
    is($result->{markets}[0]{submarkets}[0]{name}, '主要货币对', 'name  is translated');
    is_deeply(
        $result->{markets}[0]{submarkets}[0]{symbols}[0],
        {
            'symbol' => 'frxEURCAD',
            'events' => [{
                    'descrip' => 'Closes early (at 21:00)',
                    'dates'   => 'Fridays'
                }
            ],
            'name'       => "欧元/加元",
            'settlement' => '',
            'times'      => {
                'open'       => ['00:00:00'],
                'close'      => ['23:59:59'],
                'settlement' => '23:59:59'
            }
        },
        'a instance of symbol'
    );

    OUTER: for my $m (@{$result->{markets}}) {
        for my $subm (@{$m->{submarkets}}) {
            for my $sym (@{$subm->{symbols}}) {
                if ($sym->{symbol} eq 'BSESENSEX30') {
                    ok($sym->{feed_license}, 'have feed_license');
                    ok($sym->{delay_amount}, 'have delay_amount');
                    last OUTER;
                }

            }
        }
    }

};

$method = 'active_symbols';
subtest $method => sub {
    my $params = {
        language => 'ZH_CN',
        args     => {active_symbols => 'brief'}};

    my $result = $c->call_ok($method, $params)->has_no_system_error->result;
    my $expected_keys =
        [qw(market submarket submarket_display_name pip symbol symbol_type market_display_name exchange_is_open display_name  is_trading_suspended )];

    my ($indices) = grep { $_->{symbol} eq 'AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');

    $params->{args}{active_symbols} = 'full';
    push @$expected_keys, qw(exchange_name delay_amount quoted_currency_symbol intraday_interval_minutes spot spot_time spot_age);
    $result = $c->call_ok($method, $params)->has_no_system_error->result;
    ($indices) = grep { $_->{symbol} eq 'AEX' } @$result;
    is_deeply([sort keys %$indices], [sort @$expected_keys], 'result has correct keys');
    is($indices->{market_display_name},    '指数',        'the market_display_name is translated');
    is($indices->{submarket_display_name}, '欧洲/非洲', 'the submarket_display_name is translated');
    is(scalar @$result,                    102,             'the default landing company is "costarica", the number of result should be ok');

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $email = 'test@binary.com';
    $test_client->email($email);
    $test_client->save;

    my $token = BOM::Platform::SessionCookie->new(
        loginid => $test_client->loginid,
        email   => $email
    )->token;

    $params->{token} = $token;
    $result = $c->call_ok($method, $params)->has_no_system_error->result;
    is(scalar @$result, 90, 'the landing company now is maltainvest, the number of result should be ok');
};

done_testing();

