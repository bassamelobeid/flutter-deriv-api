use strict;
use warnings;
use Test::More;
use Test::MockObject;
use Test::MockModule;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Platform::Token;
use Test::Deep;
use await;
use BOM::User;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

# We don't want to fail due to hitting limits
$ENV{BOM_TEST_RATE_LIMITATIONS} = '/home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/rate_limitations.yml';

## do not send email
my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

subtest 'confirm_email Input Field Validation' => sub {
    my $email = 'test@deriv.com';
    BOM::User->create(
        email          => $email,
        password       => BOM::User::Password::hashpw('Abcd1234!'),
        email_verified => 0,
        email_consent  => 0,
    );

    my $verification_code = BOM::Platform::Token->new(
        email       => $email,
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
    my $email    = 'test1@deriv.com';
    my $hash_pwd = BOM::User::Password::hashpw('Abcd1234!');

    my $user = BOM::User->create(
        email          => $email,
        password       => $hash_pwd,
        email_verified => 0,
        email_consent  => 0,
    );

    my $verification_code = BOM::Platform::Token->new(
        email       => $email,
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

    $user = BOM::User->new(email => $email);
    ok $user->email_consent,  'Email consent updated for user';
    ok $user->email_verified, 'User is email verified';

    $user->update_email_fields(
        email_consent  => 0,
        email_verified => 0
    );

    ok !$user->email_consent,  'Email consent flag unset';
    ok !$user->email_verified, 'User marked not email verified';

    #Wrong verification token type
    $verification_code = BOM::Platform::Token->new(
        email       => $email,
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

    ok !$user->email_verified, 'User is not email verified when token verification fails';
    ok !$user->email_consent,  'Email consent not updated when token verification fails';

    #Expired verification token
    $verification_code = BOM::Platform::Token->new(
        email       => $email,
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

    ok !$user->email_verified, 'User is not email verified when token verification fails';
    ok !$user->email_consent,  'Email consent not updated when token verification fails';

    #Incorrect user
    $email = 'test2@deriv.com';

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

    $user = BOM::User->new(email => $email);
    is($user, undef, 'User not found');

    #user already verified
    $email = 'test3@gmail.com';

    $user = BOM::User->create(
        email          => $email,
        password       => $hash_pwd,
        email_verified => 1,
        email_consent  => 0,
    );

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
            code    => 'UserAlreadyVerified',
            message => 'User is already email verified.'
        },
        'Correct User already verified error'
    );

    $user = BOM::User->new(email => $email);
    ok $user->email_verified, 'User is already email verified';
    ok !$user->email_consent, 'Email consent not updated when user already verified';

    #Close websocket connection
    $t->finish_ok;
};

done_testing();

