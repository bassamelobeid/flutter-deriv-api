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

subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

subtest 'new affiliate account' => sub {
    my $password = 'Abcd33!@';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $email    = 'new_aff' . rand(999) . '@binary.com' . 'USD';
    my $user     = BOM::User->create(
        email          => $email,
        password       => $hash_pwd,
        email_verified => 1,
    );
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email,
        residence   => 'br',
    });

    my $auth_token = BOM::Platform::Token::API->new->create_token($client_vr->loginid, 'test token');

    $params->{args} = {
        affiliate_account_add => 1,
        address_city          => "Timbuktu",
        address_line_1        => "Askia Mohammed Bvd,",
        address_postcode      => "QXCQJW",
        address_state         => "Tombouctou",
        country               => "ml",
        first_name            => "John",
        last_name             => "Doe",
        non_pep_declaration   => 1,
        password              => "S3creTp4ssw0rd",
        phone                 => "+72443598863",
        tnc_accepted          => 1,
        username              => "johndoe"
    };

    my $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_error()->result;

    is $result->{error}->{code}, 'InvalidToken', 'Authorization is needed';

    $params->{token} = $auth_token;
    $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_error()->result;

    is $result->{error}->{code}, 'PermissionDenied', 'API is WIP';
    is $result->{error}->{message_to_client}, 'This API is a work in progress. AFF account will be created for landing company: Deriv Services Ltd.',
        'Proper WIP message displayed';
};

done_testing();
