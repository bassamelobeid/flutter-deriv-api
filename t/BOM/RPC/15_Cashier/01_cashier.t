use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::MockModule;
use Email::Address::UseXS;
use JSON::MaybeUTF8 qw(encode_json_utf8);

use BOM::Test::Email qw(:no_event);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::CryptoTestDatabase qw(:init);
use BOM::Test::Helper::Utility qw(random_email_address);
use BOM::Test::RPC::QueueClient;
use BOM::User;
use LWP::UserAgent;
require Test::NoWarnings;

# this must be declared at the end, otherwise BOM::Test::Email will fail
use Test::Most;

my $mocked_call = Test::MockModule->new('LWP::UserAgent');

my $rpc_ct;
subtest 'Initialization' => sub {
    lives_ok {
        $rpc_ct = BOM::Test::RPC::QueueClient->new();
    }
    'Initial RPC server and client connection';
};

my $email          = random_email_address;
my $user_client_cr = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw('jskjd8292922'),
    email_verified => 1,
);
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    email          => $email,
    place_of_birth => 'id',
});
$client_cr->set_default_account('USD');

$user_client_cr->add_client($client_cr);

subtest 'Doughflow' => sub {
    my $params = {};
    $params->{args}->{cashier} = 'deposit';
    $params->{token}           = BOM::Platform::Token::API->new->create_token($client_cr->loginid, 'test token123');
    $params->{domain}          = 'binary.com';

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/frontend not found/, 'No frontend error');

    $mocked_call->mock('post', sub { return {_content => 'customer too old'} });

    mailbox_clear();

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/customer too old/, 'Customer too old error')
        ->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    my $msg = mailbox_search(subject => qr/DOUGHFLOW_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/over 110 years old/, "Correct message to too old";

    $mocked_call->mock('post', sub { return {_content => 'customer underage'} });

    mailbox_clear();

    $rpc_ct->call_ok('cashier', $params)
        ->has_no_system_error->has_error->error_internal_message_like(qr/customer underage/, 'Customer underage error')->error_message_is(
        'Sorry, there was a problem validating your personal information with our payment processor. Please verify that your date of birth was input correctly in your account settings.',
        'Correct client message to user underage'
        );

    $msg = mailbox_search(subject => qr/DOUGHFLOW_MIN_AGE_LIMIT_EXCEEDED/);

    like $msg->{body}, qr/under 18 years/, "Correct message to underage";

    $mocked_call->mock('post', sub { return {_content => 'abcdef'} });

    $rpc_ct->call_ok('cashier', $params)->has_no_system_error->has_error->error_internal_message_like(qr/abcdef/, 'Unknown Doughflow error')
        ->error_message_is('Sorry, an error occurred. Please try accessing our cashier again.', 'Correct Unknown Doughflow error message');
};

subtest 'Crypto cashier calls' => sub {
    my $new_email = random_email_address;
    my $user      = BOM::User->create(
        email          => $new_email,
        password       => BOM::User::Password::hashpw('somepasswd123'),
        email_verified => 1,
    );
    my $client_info = {
        broker_code    => 'CR',
        email          => $new_email,
        place_of_birth => 'id',
    };

    my $client_fiat = BOM::Test::Data::Utility::UnitTestDatabase::create_client({$client_info->%*});
    $client_fiat->set_default_account('USD');
    $user->add_client($client_fiat);

    my $client_crypto = BOM::Test::Data::Utility::UnitTestDatabase::create_client({$client_info->%*});
    $client_crypto->set_default_account('BTC');
    $user->add_client($client_crypto);

    my $token_fiat   = BOM::Platform::Token::API->new->create_token($client_fiat->loginid,   'test token');
    my $token_crypto = BOM::Platform::Token::API->new->create_token($client_crypto->loginid, 'test token');

    my $common_expected_result = {
        stash => {
            valid_source               => 1,
            app_markup_percentage      => 0,
            source_bypass_verification => 0,
        },
    };

    my $calls = [{
            call_name    => 'cashier',
            call_display => 'cashier: deposit',
            args         => {
                cashier  => 'deposit',
                provider => 'crypto',
                type     => 'api',
            },
            api_response => {
                deposit_address => 'test_deposit_address',
            },
            rpc_response => {
                action  => 'deposit',
                deposit => {
                    address => 'test_deposit_address',
                },
            },
        },
        {
            call_name    => 'cashier',
            call_display => 'cashier: withdraw (dry-run)',
            args         => {
                cashier           => 'withdraw',
                provider          => 'crypto',
                type              => 'api',
                address           => 'withdrawal_address',
                amount            => 1,
                verification_code => 'verification_code',
                dry_run           => 1,
            },
            api_response => {
                dry_run => 1,
            },
            rpc_response => {
                action   => 'withdraw',
                withdraw => {
                    dry_run => 1,
                },
            },
        },
        {
            call_name    => 'cashier',
            call_display => 'cashier: withdraw',
            args         => {
                cashier           => 'withdraw',
                provider          => 'crypto',
                type              => 'api',
                address           => 'withdrawal_address',
                amount            => 1,
                verification_code => 'verification_code',
            },
            api_response => {
                id             => 1,
                status_code    => 'LOCKED',
                status_message => 'Sample status message',
            },
            rpc_response => {
                action   => 'withdraw',
                withdraw => {
                    id             => 1,
                    status_code    => 'LOCKED',
                    status_message => 'Sample status message',
                },
            },
        },
        {
            call_name => 'cashier_withdrawal_cancel',
            args      => {
                cashier_withdrawal_cancel => 1,
                id                        => 2,
            },
            api_response => {
                id          => 2,
                status_code => 'CANCELLED',
            },
        },
        {
            call_name => 'cashier_payments',
            args      => {
                cashier_payments => 1,
                provider         => 'crypto',
                transaction_type => 'all',
            },
            api_response => {
                crypto => [],
            },
        },
    ];

    my $api_error_response = {
        error => {
            code    => 'CryptoSampleErrorCode',
            message => 'Sample error message',
        }};
    my $fiat_error_response = {
        error => {
            code    => 'InvalidRequest',
            message => 'Crypto cashier is unavailable for fiat currencies.',
        }};

    my $api_response  = {};
    my $http_response = HTTP::Response->new(200);
    $mocked_call->mock($_ => sub { $http_response->content(encode_json_utf8($api_response)); $http_response; }) for qw(get post);

    my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
    $mock_utility->mock(is_verification_token_valid => sub { +{status => 1} });

    for my $call_info ($calls->@*) {
        $api_response = {$call_info->{api_response}->%*};
        my $rpc_response = {($call_info->{rpc_response} // $api_response)->%*};
        my $params       = {args => $call_info->{args}};
        my $call_name    = $call_info->{call_name};
        my $call_display = $call_info->{call_display} // $call_name;

        $params->{token} = $token_fiat;
        my $expected_result = {$common_expected_result->%*, $fiat_error_response->%*};
        $rpc_ct->call_ok($call_name, $params)->has_no_system_error->has_error->error_code_is($fiat_error_response->{error}{code},
            "Correct error code when fiat account used for $call_display")
            ->error_message_is($fiat_error_response->{error}{message}, "Correct error message when fiat account used for $call_display");

        $params->{token} = $token_crypto;
        $expected_result = {$common_expected_result->%*, $rpc_response->%*};
        $rpc_ct->call_ok($call_name, $params)
            ->has_no_system_error->has_no_error->result_is_deeply($expected_result, "Correct response for $call_display");

        $api_response    = $api_error_response;
        $expected_result = {$common_expected_result->%*, $api_error_response->%*};
        $rpc_ct->call_ok($call_name, $params)
            ->has_no_system_error->has_error->error_code_is($api_error_response->{error}{code}, "Correct error code for $call_display")
            ->error_message_is($api_error_response->{error}{message}, "Correct error message for $call_display");
    }

    $mock_utility->unmock_all;
    $mocked_call->unmock_all;
};

subtest 'validate_amount' => sub {
    my $mocked_fun = Test::MockModule->new('Format::Util::Numbers');
    $mocked_fun->mock('get_precision_config', sub { return {amount => {'BBB' => 5}} });
    is(BOM::RPC::v3::Cashier::validate_amount(0.00001, 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1e-05,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('1e-05', 'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount('fred',  'BBB'), 'Invalid amount.', 'Invalid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(0.001,   'BBB'), undef,             'Valid Amount');
    is(BOM::RPC::v3::Cashier::validate_amount(1,       'BBB'), undef,             'Valid Amount');
    is(
        BOM::RPC::v3::Cashier::validate_amount(0.000001, 'BBB'),
        'Invalid amount. Amount provided can not have more than 5 decimal places.',
        'Too many decimals'
    );
};

done_testing();
