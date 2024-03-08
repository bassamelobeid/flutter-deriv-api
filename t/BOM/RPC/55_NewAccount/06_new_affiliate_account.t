use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::MockModule;
use Test::FailWarnings;
use Test::Warn;
use Test::Fatal qw(lives_ok exception);

use Date::Utility;
use MojoX::JSON::RPC::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Test::Email qw(:no_event);
use BOM::Platform::Token;
use BOM::User::Client;
use JSON::MaybeUTF8 qw(encode_json_utf8 decode_json_utf8);
use BOM::Database::Model::OAuth;
use BOM::Platform::Token::API;

use IO::Pipe;
use BOM::RPC::v3::Services::MyAffiliates;

my $app = BOM::Database::Model::OAuth->new->create_app({
    name    => 'test',
    scopes  => '{read,admin,trade,payments}',
    user_id => 1
});

my $app_id = $app->{app_id};
my $rpc_ct;
my $aff_cli;
isnt($app_id, 1, 'app id is not 1');    # There was a bug that the created token will be always app_id 1; We want to test that it is fixed.

my %emitted;
my $emit_data;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(
    'emit',
    sub {
        my ($type, $data) = @_;

        $emit_data = $data;

        my $loginid = $data->{loginid};

        return unless $loginid;

        ok !$emitted{$type . '_' . $loginid}, "First (and hopefully unique) signup event for $loginid" if $type eq 'signup';

        $emitted{$type . '_' . $loginid}++;
    });

my %datadog_args;
my $mock_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
$mock_datadog->mock(
    'stats_inc' => sub {
        my $key  = shift;
        my $args = shift;
        $datadog_args{$key} = $args;
    },
);

my $params = {
    language => 'EN',
    source   => $app_id,
    country  => 'ru',
    args     => {},
};

my $mt5_args;
my $mt5_mock = Test::MockModule->new('BOM::MT5::User::Async');
$mt5_mock->mock(
    'create_user',
    sub {
        ($mt5_args) = @_;
        return $mt5_mock->original('create_user')->(@_);
    });

my $mock_myaffiliate_server = Test::MockModule->new('BOM::MyAffiliates::WebService');
$mock_myaffiliate_server->mock(
    'register_affiliate',
    sub {
        return Future->done(1);
    });

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $mock_myAffiliate_server = Test::MockModule->new('BOM::MyAffiliates::WebService');
$mock_myAffiliate_server->mock(
    'register_affiliate',
    sub {
        return Future->done(1);
    });

subtest 'new affiliate account MyAffiliate die with MYAFFRuntimeError error' => sub {
    $mock_myAffiliate_server->unmock_all();
    $mock_myAffiliate_server->redefine(
        'register_affiliate',
        sub {
            return Future->fail('website does not exist');
        });

    my $email = 'new_aff' . rand(999) . '@deriv.com';

    $params->{args} = {
        affiliate_register_person => 1,
        address_city              => "nouaceur",
        address_postcode          => "123452",
        address_state             => "BA",
        address_street            => "someplace",
        bta                       => 12345,
        citizenship               => "id",
        country                   => "id",
        commission_plan           => 2,
        company_name              => "XYZltd",
        currency                  => "USD",
        date_of_birth             => "1992-1-2",
        email                     => $email,
        first_name                => "affiliatefirstname",
        last_name                 => "affiliatelastname",
        non_pep_declaration       => 1,
        over_18_declaration       => 1,
        phone_code                => 971,
        phone                     => "+971541234",
        tnc_accepted              => 1,
        tnc_affiliate_accepted    => 1,
        type_of_account           => 1,
        user_name                 => "MyAffUser" . rand(999),
        whatsapp_number_phoneCode => 971,
        whatsapp_number           => "+971541233",
        website_url               => "xyz.com"
    };

    $rpc_ct->call_ok('affiliate_register_person', $params)->has_error->error_code_is(400);
};

subtest 'new affiliate account MyAffiliate successful' => sub {
    $mock_myAffiliate_server->unmock_all();
    $mock_myAffiliate_server->redefine(
        'register_affiliate',
        sub {
            return Future->done(1);
        });

    my $email = 'new_aff' . rand(999) . '@deriv.com';

    $params->{args} = {
        affiliate_register_person => 1,
        address_city              => "nouaceur",
        address_postcode          => "123452",
        address_state             => "BA",
        address_street            => "someplace",
        bta                       => 12345,
        citizenship               => "id",
        country                   => "id",
        commission_plan           => 2,
        company_name              => "XYZltd",
        currency                  => "USD",
        date_of_birth             => "1992-01-02",
        email                     => $email,
        first_name                => "affiliatefirstname",
        last_name                 => "affiliatelastname",
        non_pep_declaration       => 1,
        over_18_declaration       => 1,
        phone_code                => 971,
        phone                     => "+971541234",
        tnc_accepted              => 1,
        tnc_affiliate_accepted    => 1,
        type_of_account           => 1,
        user_name                 => "MyAffUser" . rand(999),
        whatsapp_number_phoneCode => 971,
        whatsapp_number           => "+971541233",
        website_url               => "www.xyz.com"
    };

    my $result = $rpc_ct->call_ok('affiliate_register_person', $params)->has_no_system_error->result;
};

subtest 'new affiliate business account MyAffiliate successful' => sub {
    $mock_myAffiliate_server->unmock_all();
    $mock_myAffiliate_server->redefine(
        'register_affiliate',
        sub {
            return Future->done(1);
        });

    my $email = 'new_aff' . rand(999) . '@deriv.com';

    $params->{args} = {
        affiliate_register_person   => 1,
        address_city                => "nouaceur",
        address_postcode            => "123452",
        address_state               => "BA",
        address_street              => "someplace",
        bta                         => 12345,
        citizenship                 => "id",
        country                     => "id",
        commission_plan             => 2,
        company_name                => "XYZltd",
        company_registration_number => "123456789",
        currency                    => "USD",
        date_of_birth               => "1992-01-02",
        email                       => $email,
        first_name                  => "affiliatefirstname",
        last_name                   => "affiliatelastname",
        non_pep_declaration         => 1,
        over_18_declaration         => 1,
        phone_code                  => 971,
        phone                       => "+971541234",
        tnc_accepted                => 1,
        tnc_affiliate_accepted      => 1,
        type_of_account             => 2,
        user_name                   => "MyAffUser" . rand(999),
        whatsapp_number_phoneCode   => 971,
        whatsapp_number             => "+971541233",
        website_url                 => "www.xyz.com"
    };

    my $result = $rpc_ct->call_ok('affiliate_register_person', $params)->has_no_system_error->result;
};

subtest 'new affiliate business account die with MYAFFRuntimeError error' => sub {
    $mock_myAffiliate_server->unmock_all();
    $mock_myAffiliate_server->redefine(
        'register_affiliate',
        sub {
            return Future->fail('Company name and company registration number are required for business account');
        });

    my $email = 'new_aff' . rand(999) . '@deriv.com';

    $params->{args} = {
        affiliate_register_person => 1,
        address_city              => "nouaceur",
        address_postcode          => "123452",
        address_state             => "BA",
        address_street            => "someplace",
        bta                       => 12345,
        citizenship               => "id",
        country                   => "id",
        commission_plan           => 2,
        company_name              => "XYZltd",
        currency                  => "USD",
        date_of_birth             => "1992-01-02",
        email                     => $email,
        first_name                => "affiliatefirstname",
        last_name                 => "affiliatelastname",
        non_pep_declaration       => 1,
        over_18_declaration       => 1,
        phone_code                => 971,
        phone                     => "+971541234",
        tnc_accepted              => 1,
        tnc_affiliate_accepted    => 1,
        type_of_account           => 2,
        user_name                 => "MyAffUser" . rand(999),
        whatsapp_number_phoneCode => 971,
        whatsapp_number           => "+971541233",
        website_url               => "www.xyz.com"
    };

    my $result = $rpc_ct->call_ok('affiliate_register_person', $params)->has_error->error_code_is(400);
};

subtest 'new affiliate account with password MyAffiliate successful' => sub {
    $mock_myAffiliate_server->unmock_all();
    $mock_myAffiliate_server->redefine(
        'register_affiliate',
        sub {
            return Future->done(1);
        });

    my $email = 'new_aff' . rand(999) . '@deriv.com';

    $params->{args} = {
        affiliate_register_person => 1,
        address_city              => "nouaceur",
        address_postcode          => "123452",
        address_state             => "BA",
        address_street            => "someplace",
        bta                       => 12345,
        citizenship               => "id",
        country                   => "id",
        commission_plan           => 2,
        company_name              => "XYZltd",
        currency                  => "USD",
        date_of_birth             => "1992-01-02",
        email                     => $email,
        first_name                => "affiliatefirstname",
        last_name                 => "affiliatelastname",
        non_pep_declaration       => 1,
        over_18_declaration       => 1,
        password                  => "Abc@1234",
        phone_code                => 971,
        phone                     => "+971541234",
        tnc_accepted              => 1,
        tnc_affiliate_accepted    => 1,
        type_of_account           => 1,
        user_name                 => "MyAffUser" . rand(999),
        whatsapp_number_phoneCode => 971,
        whatsapp_number           => "+971541233",
        website_url               => "www.xyz.com"
    };

    my $result = $rpc_ct->call_ok('affiliate_register_person', $params)->has_no_system_error->result;
};

done_testing();
