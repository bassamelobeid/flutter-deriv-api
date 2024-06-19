use strict;
use warnings;
use Test::More;

use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test call_mocked_consumer_groups_request/;
use Test::MockModule;
use BOM::Config::Runtime;
use BOM::Test::Helper::ExchangeRates             qw/populate_exchange_rates/;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use JSON::MaybeUTF8                              qw/decode_json_utf8/;
use URL::Encode                                  qw/url_encode/;

use await;

my $t = build_wsapi_test();

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

## residence_list
$t->get_ok('/websockets/residence_list?app_id=1&l=EN&brand=deriv')->status_is(200)->json_is('/msg_type' => 'residence_list');
my $res = $t->tx->res->json;
ok $res->{residence_list};
my $countries = +{map { ($_->{value} => $_) } $res->{residence_list}->@*};
is_deeply $countries->{ir}, {
    disabled  => 'DISABLED',
    value     => 'ir',
    text      => 'Iran',
    phone_idd => '98',
    identity  => {
        services => {
            idv => {
                documents_supported => {

                },
                is_country_supported => 0,
                has_visual_sample    => 0,
            },
            onfido => {
                documents_supported => {
                    driving_licence => {
                        display_name => 'Driving Licence',
                    },
                    passport => {
                        display_name => 'Passport',
                    },
                },
                is_country_supported => 0,
            }}}};
test_schema('residence_list', $res);

populate_exchange_rates();

## exchage_rates
$t->post_ok('/websockets/exchange_rates?app_id=1&l=EN&brand=deriv' => json => {base_currency => "USD"})->status_is(200)
    ->json_is('/msg_type' => 'exchange_rates')->json_is('/exchange_rates/base_currency' => 'USD');
$res = $t->tx->res->json;
test_schema('exchange_rates', $res);

## exchage_rates with get
$t->get_ok('/websockets/exchange_rates?app_id=1&l=EN&brand=deriv&request_json=' . url_encode('{"base_currency":"USD"}'))->status_is(200)
    ->json_is('/msg_type' => 'exchange_rates')->json_is('/exchange_rates/base_currency' => 'USD');
$res = $t->tx->res->json;
test_schema('exchange_rates', $res);

$t->finish_ok;

done_testing();
