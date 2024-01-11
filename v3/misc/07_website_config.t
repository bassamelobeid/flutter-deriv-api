use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::MockObject;
use JSON::MaybeUTF8 qw/decode_json_utf8 encode_json_utf8/;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/build_wsapi_test test_schema/;
use Test::MockModule;
use Mojo::Redis2;
use Clone;
use BOM::Config::Chronicle;
use BOM::Test::Helper::ExchangeRates             qw/populate_exchange_rates/;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Config::Runtime;

#we need this because of calculating max exchange rates on currency config
populate_exchange_rates();
print STDERR "pid of script is $$\n";

my $reader = BOM::Config::Chronicle::get_chronicle_reader();
my $writer = BOM::Config::Chronicle::get_chronicle_writer();

my $c = BOM::Test::RPC::QueueClient->new();
my $t = build_wsapi_test();

my $method = 'website_config';
my $params = {country_code => 'id'};

subtest 'website_config' => sub {
    my $res = $c->call_ok($method, $params)->result;
    ok(defined $res, 'website_config RPC call returns a result');

    cmp_deeply(
        $res,
        superhashof({
                feature_flags            => ignore(),
                currencies_config        => ignore(),
                payment_agents           => ignore(),
                supported_languages      => ignore(),
                terms_conditions_version => ignore(),
            }
        ),
        'website_config RPC call returns a result with the expected keys'
    );
};

subtest 'feature_flags' => sub {

    my $expected_feature_flags = ['signup_with_optional_email_verification'];
    my $app_config             = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    $app_config->set({'email_verification.suspend.virtual_accounts' => 1});
    my $res = $c->call_ok($method, $params)->result;
    ok($app_config->get('email_verification.suspend.virtual_accounts'), 'email_verification.suspend.virtual_accounts should be set to 1');

    cmp_deeply($res->{feature_flags}->@*, @$expected_feature_flags, 'feature_flags value is correct from chronicle');

    $app_config->set({'email_verification.suspend.virtual_accounts' => 0});
    $res = $c->call_ok($method, $params)->result;
    ok(!$app_config->get('email_verification.suspend.virtual_accounts'), 'email_verification.suspend.virtual_accounts should be set to 0');

    cmp_deeply($res->{feature_flags}, [], 'feature_flags value is empty from chronicle');
};

subtest 'terms_conditions_version' => sub {

    my $app_config  = BOM::Config::Runtime->instance->app_config();
    my $tnc_config  = $app_config->get('cgi.terms_conditions_versions');
    my $tnc_version = decode_json_utf8($tnc_config)->{binary};

    my $res = $c->call_ok($method, $params)->result;

    cmp_deeply($res->{terms_conditions_version}, $tnc_version, 'terms_conditions_version should be readed from chronicle');

    # Update terms_conditions_version at chronicle
    $tnc_version = 'Version 100 ' . Date::Utility->new->date;
    my $json_config = {binary => $tnc_version};

    $app_config->set({'cgi.terms_conditions_versions' => encode_json_utf8($json_config)});

    $tnc_config  = $app_config->get('cgi.terms_conditions_versions');
    $tnc_version = decode_json_utf8($tnc_config)->{binary};

    ok $tnc_version eq $json_config->{binary}, 'Chronickle should be updated';

    $res = $c->call_ok($method, $params)->result;
    cmp_deeply($res->{terms_conditions_version}, $tnc_version, 'It should return updated terms_conditions_version');

};

subtest 'supported_languages' => sub {

    my $app_config          = BOM::Config::Runtime->instance->app_config();
    my $supported_languages = $app_config->get('cgi.supported_languages');

    my $res = $c->call_ok($method, $params)->result;

    cmp_deeply($res->{supported_languages}, $supported_languages, 'supported_languages should be readed from chronicle');

};

done_testing();
