use strict;
use warnings;
use Test::More;
use Test::MockObject;
use Test::MockModule;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::Deep;
use await;

use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Test::Customer;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Token;
use BOM::Service;
use BOM::User;

# We don't want to fail due to hitting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

## do not send email
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

subtest 'confirm_email Input Field Validation' => sub {
    my $customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            },
        ]);

    my $verification_code = BOM::Platform::Token->new(
        email       => $customer->get_email(),
        created_for => 'account_verification',
    )->token;

    my $confirm_user = {
        confirm_email     => 1,
        verification_code => $verification_code,
        email_consent     => 1
    };

    my $t   = build_wsapi_test();
    my $res = $t->await::confirm_email($confirm_user);
    is($res->{msg_type}, 'confirm_email');
    ok($res->{confirm_email}, 'confirm_email RPC response success');
    test_schema('confirm_email', $res);

    #Missing verification code
    delete $confirm_user->{verification_code};
    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    cmp_deeply(
        $res->{error},
        {
            code    => 'InputValidationFailed',
            details => {verification_code => 'Missing property.'},
            message => 'Input validation failed: verification_code'
        },
        'Missing verification code error'
    );

    #Missing email consent
    $confirm_user->{verification_code} = $verification_code;
    delete $confirm_user->{email_consent};
    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    cmp_deeply(
        $res->{error},
        {
            code    => 'InputValidationFailed',
            details => {email_consent => 'Missing property.'},
            message => 'Input validation failed: email_consent'
        },
        'Missing email consent error'
    );

    #missing both verification code and email consent
    delete $confirm_user->{verification_code};
    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
};

subtest 'confirm_email token validation' => sub {
    my $customer = BOM::Test::Customer->create(
        clients => [{
                name        => 'CR',
                broker_code => 'CR',
            },
        ]);

    my $verification_code = BOM::Platform::Token->new(
        email       => $customer->get_email(),
        created_for => 'account_verification',
    )->token;

    my $confirm_user = {
        confirm_email     => 1,
        verification_code => $verification_code,
        email_consent     => 1
    };

    my $t   = build_wsapi_test();
    my $res = $t->await::confirm_email($confirm_user);

    is($res->{msg_type}, 'confirm_email');
    ok($res->{confirm_email}, 'confirm_email RPC response sucess');
    test_schema('confirm_email', $res);

    my $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_email(),
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'ok', 'user service call succeeded');
    ok($user_data->{attributes}{email_verified}, 'Email consent updated for user');
    ok($user_data->{attributes}{email_consent},  'User is email verified');

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'update_attributes',
        user_id    => $customer->get_email(),
        attributes => {
            email_consent  => 0,
            email_verified => 0
        },
    );
    is $user_data->{status}, 'ok', 'user service call succeeded';

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_email(),
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'ok', 'user service call succeeded');
    ok(!$user_data->{attributes}{email_verified}, 'Email consent flag unset');
    ok(!$user_data->{attributes}{email_consent},  'User marked not email verified');

    #Wrong verification token type
    $verification_code = BOM::Platform::Token->new(
        email       => $customer->get_email(),
        created_for => 'account_opening',
    )->token;

    $confirm_user->{verification_code} = $verification_code;

    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    test_schema('confirm_email', $res);
    cmp_deeply(
        $res->{error},
        {
            code    => 'InvalidToken',
            message => 'Your token has expired or is invalid.'
        },
        'Invalid token error'
    );

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_email(),
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'ok', 'user service call succeeded');
    ok(!$user_data->{attributes}{email_verified}, 'User is not email verified when token verification fails');
    ok(!$user_data->{attributes}{email_consent},  'Email consent not updated when token verification fails');

    #Expired verification token
    $verification_code = BOM::Platform::Token->new(
        email       => $customer->get_email(),
        created_for => 'account_verification',
        expires_in  => -1
    )->token;

    $confirm_user->{verification_code} = $verification_code;

    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    cmp_deeply(
        $res->{error},
        {
            code    => 'InvalidToken',
            message => 'Your token has expired or is invalid.'
        },
        'Expired token error'
    );

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_email(),
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'ok', 'user service call succeeded');
    ok(!$user_data->{attributes}{email_verified}, 'User is not email verified when token verification fails');
    ok(!$user_data->{attributes}{email_consent},  'Email consent not updated when token verification fails');

    #Incorrect user
    my $email = 'test2@deriv.com';

    $verification_code = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'account_verification',
    )->token;

    $confirm_user->{verification_code} = $verification_code;

    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    test_schema('confirm_email', $res);
    cmp_deeply(
        $res->{error},
        {
            code    => 'InvalidUser',
            message => 'No user found.'
        },
        'Incorrect user error as user not found for email extracted from token'
    );

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $email,
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'error',        'User not found');
    is($user_data->{class},  'UserNotFound', 'User not found');

    #user already verified
    $customer = BOM::Test::Customer->create(
        email_verified => 1,
        email_consent  => 0,
        clients        => [{
                name        => 'CR',
                broker_code => 'CR',
            },
        ]);

    $verification_code = BOM::Platform::Token->new(
        email       => $customer->get_email(),
        created_for => 'account_verification',
    )->token;

    $confirm_user->{verification_code} = $verification_code;

    $res = $t->await::confirm_email($confirm_user);
    ok($res->{error}, 'confirm_email RPC response error');
    test_schema('confirm_email', $res);
    cmp_deeply(
        $res->{error},
        {
            code    => 'UserAlreadyVerified',
            message => 'User is already email verified.'
        },
        'Correct User already verified error'
    );

    $user_data = BOM::Service::user(
        context    => $customer->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $customer->get_email(),
        attributes => [qw(email_consent email_verified)],
    );
    is($user_data->{status}, 'ok', 'user service call succeeded');
    ok($user_data->{attributes}{email_verified}, 'User is already email verified');
    ok(!$user_data->{attributes}{email_consent}, 'Email consent not updated when user already verified');

    #Close websocket connection
    $t->finish_ok;
};

done_testing();

