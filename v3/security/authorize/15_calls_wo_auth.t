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

use await;

my $t = build_wsapi_test();

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR EURS PAX ETH IDK AUD eUSDT tUSDT BTC USDK LTC USB UST USDC TUSD USD GBP DAI BUSD);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

# landing_company_details
my $res = $t->await::landing_company_details({landing_company_details => 'svg'});
ok $res->{landing_company_details};
is $res->{landing_company_details}->{country}, 'Saint Vincent and the Grenadines';
test_schema('landing_company_details', $res);

$res = $t->await::landing_company_details({landing_company_details => 'iom'});
ok $res->{landing_company_details};
is $res->{landing_company_details}->{country}, 'Isle of Man';
test_schema('landing_company_details', $res);

$res = $t->await::landing_company_details({landing_company_details => 'unknown_blabla'});
ok $res->{error};
is $res->{error}->{code}, 'InputValidationFailed';

# landing_company
$res = $t->await::landing_company({landing_company => 'de'});
ok $res->{landing_company};
is $res->{landing_company}->{name},                           'Germany';
is $res->{landing_company}->{financial_company}->{shortcode}, 'maltainvest';
is $res->{landing_company}->{gaming_company}->{shortcode},    undef;
test_schema('landing_company', $res);

$res = $t->await::landing_company({landing_company => 'im'});
ok $res->{landing_company};
is $res->{landing_company}->{name},                           'Isle of Man';
is $res->{landing_company}->{financial_company}->{shortcode}, undef;
is $res->{landing_company}->{gaming_company}->{shortcode},    undef;
test_schema('landing_company', $res);

$res = $t->await::landing_company({landing_company => 'XX'});
ok $res->{error};
is $res->{error}->{code}, 'UnknownLandingCompany';

## residence_list
$res = $t->await::residence_list({residence_list => 1});
ok $res->{residence_list};
is_deeply $res->{residence_list}->[104], {
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

## states_list
$res = $t->await::states_list({states_list => 'MY'});
is $res->{msg_type}, 'states_list';
ok $res->{states_list};
is_deeply $res->{states_list}->[0],
    {
    value => '01',
    text  => 'Johor'
    };
test_schema('states_list', $res);

$res = $t->await::states_list({states_list => 'CW'});
is $res->{msg_type}, 'states_list';
ok $res->{states_list};
is_deeply $res->{states_list}->[0],
    {
    value => '00',
    text  => 'Curacao'
    };
test_schema('states_list', $res);

populate_exchange_rates();

## website_status
my (undef, $call_params) = call_mocked_consumer_groups_request($t, {website_status => 1});
ok $call_params->{country_code};

BOM::Config::Runtime->instance->app_config->check_for_update(1);

$res = $t->await::website_status({website_status => 1});
is $res->{msg_type}, 'website_status';
my $tnc_config  = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_versions;
my $tnc_version = decode_json_utf8($tnc_config)->{binary};
is $res->{website_status}->{terms_conditions_version}, $tnc_version;

## exchage_rates
$res = $t->await::exchange_rates({
    exchange_rates => 1,
    base_currency  => "USD"
});
is $res->{msg_type}, 'exchange_rates', 'Exchange rates received';
test_schema('exchange_rates', $res);

$t->finish_ok;

done_testing();
