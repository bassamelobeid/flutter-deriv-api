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
    my $email    = 'new_aff' . rand(999) . '@binary.com';
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
        date_of_birth  => '1989-10-10',
        affiliate_plan => undef,
        residence      => 'br',
    };

    $params->{token} = $auth_token;
    my $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_error()->result;

    is $result->{error}->{code}, 'InsufficientAccountDetails', 'affiliate plan is mandatory';
    is $result->{error}->{details}->{missing}[0], 'affiliate_plan', 'affiliate plan is mandatory';

    $params->{args} = {
        date_of_birth  => '1989-10-10',
        affiliate_plan => 'turnover',
        residence      => 'br',
        address_line_1 => 'nowhere',
        affiliate_plan => 'turnover',
        first_name     => 'test',
        last_name      => 'asdf',
    };
    $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_no_error()->result;
    my $lc = LandingCompany::Registry->by_broker('AFF');

    ok $result->{client_id} =~ /^AFF[0-9]+$/, 'Got a valid AFF broker code';
    is $result->{landing_company},           $lc->name,  'Got the landing_company';
    is $result->{landing_company_shortcode}, $lc->short, 'Got the landing_company_shortcode';
    ok $result->{oauth_token} =~ /^a1-.+$/, 'Got a valid oauth_token';
    is $result->{currency}, 'USD', 'AFF accounts are always USD accounts';

    subtest 'affiliate info set' => sub {
        $aff_cli = BOM::User::Client->rnew(loginid => $result->{client_id});
        lives_ok { $aff_cli = $aff_cli->get_client_instance($aff_cli->loginid) } 'Can retrieve an Affiliate instance';
        isa_ok $aff_cli, 'BOM::User::Affiliate', 'Expected affiliate instance';

        cmp_deeply $aff_cli->get_affiliate_info(),
            {
            affiliate_loginid => $aff_cli->loginid,
            affiliate_plan    => 'turnover'
            },
            'Expected data set';
    };
};

subtest 'new affiliate account with currency' => sub {
    my $password = 'Abcd33!@';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    my $email    = 'new_aff_usd' . rand(999) . '@binary.com';
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
        date_of_birth  => '1989-10-10',
        currency       => 'USD',
        residence      => 'br',
        first_name     => 'Someguy',
        last_name      => 'The Affiliate',
        address_line_1 => 'nowhere',
        affiliate_plan => 'turnover',
    };

    $params->{token} = $auth_token;

    my $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_no_error()->result;
    my $lc     = LandingCompany::Registry->by_broker('AFF');

    ok $result->{client_id} =~ /^AFF[0-9]+$/, 'Got a valid AFF broker code';
    is $result->{landing_company},           $lc->name,  'Got the landing_company';
    is $result->{landing_company_shortcode}, $lc->short, 'Got the landing_company_shortcode';
    ok $result->{oauth_token} =~ /^a1-.+$/, 'Got a valid oauth_token';
    is $result->{currency}, 'USD', 'Currency set';

    my $cli = BOM::User::Client->rnew(loginid => $result->{client_id});
    lives_ok { $cli = $cli->get_client_instance($cli->loginid) } 'Can retrieve an Affiliate instance';
    isa_ok $cli, 'BOM::User::Affiliate', 'Expected affiliate instance';
    is $cli->account->currency_code, 'USD', 'usd account created';

    subtest 'account limit reached' => sub {
        $result = $rpc_ct->call_ok('affiliate_account_add', $params)->has_no_system_error->has_error()->result;
        is $result->{error}->{code}, 'NewAccountLimitReached', 'Cannot open two accounts';
    };
};

done_testing();
