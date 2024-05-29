use strict;
use warnings;
use Test::More;
use Test::MockObject;
use JSON::MaybeUTF8 qw/decode_json_utf8/;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use Test::MockModule;
use Mojo::Redis2;
use Clone;
use BOM::Config::Chronicle;
use BOM::RPC::v3::Static;
use BOM::Test::Helper::ExchangeRates             qw/populate_exchange_rates/;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

#we need this because of calculating max exchange rates on currency config
populate_exchange_rates();

my $reader = BOM::Config::Chronicle::get_chronicle_reader();
my $writer = BOM::Config::Chronicle::get_chronicle_writer();

my $tnc_config  = BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_versions;
my $tnc_version = decode_json_utf8($tnc_config)->{binary};

my $t = build_wsapi_test();
#A couple of simple tests, as we assiume that the functionality should be identical to the websocket version (maybe we should abstract the tests to be able to call both?)
$t->get_ok('/websockets/website_status?app_id=1&l=EN&brand=deriv')->status_is(200)->json_is('/msg_type' => 'website_status');
$t->get_ok('/websockets/website_status?app_id=1&l=EN&brand=deriv')->status_is(200)
    ->json_like('/website_status/terms_conditions_version' => qr/^Version/);
$t->get_ok('/websockets/website_status?app_id=1&l=EN&brand=deriv')->status_is(200)->json_like('/website_status/clients_country' => qr/^[a-z][a-z]$/);

done_testing();
