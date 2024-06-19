use strict;
use warnings;
use utf8;

use Test::Most;
use Test::FailWarnings;

use BOM::Platform::Token;

my $loginid  = 'VRTC10001';
my $password = 'abc123';
my $email    = 'xyz@binary.com';

throws_ok {
    my $token = BOM::Platform::Token->new(email => $email);
}
qr/created_for /, 'created_for parameter is mandatory';

my $token = BOM::Platform::Token->new(
    email       => $email,
    created_for => 'verify_email'
);

ok $token->token, 'Token created successfully';

is length $token->token, 8, 'Correct length for token';

$token = BOM::Platform::Token->new({token => $token->token});
is $token->validate_token(), 1,              'Token is valid';
is $token->{created_for},    'verify_email', 'Token is valid, got correct created_for';

ok $token->delete_token(), 'token deleted successfully';

$token = BOM::Platform::Token->new({token => $token->token});
is $token->token, undef, "Can't created token from already deleted one";

#Testing the token handler with the created_by parameter
my $test_loginid = 'CR10002';
$token = BOM::Platform::Token->new(
    email       => $email,
    created_for => 'request_email',
    created_by  => $test_loginid
);

ok $token->token, 'Token is created successfully with the created_by parameter';

is length $token->token, 8, 'Correct length for token';

$token = BOM::Platform::Token->new({token => $token->token});
is $token->validate_token(), 1,               'Token is valid';
is $token->{created_for},    'request_email', 'Token is valid, got correct created_for';

subtest 'custom arguments' => sub {
    $token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'phone_number_verification',
        created_by  => $test_loginid,
        length      => 6,
        alphabet    => ['0' .. '9'],
    );

    ok $token->token =~ /\d{6}/, 'Expected a 6 digit token';

    $token = BOM::Platform::Token->new({token => $token->token});
    is $token->validate_token(), 1,                           'Token is valid';
    is $token->{created_for},    'phone_number_verification', 'Token is valid, got correct created_for';

    $token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'phone_number_verification',
        created_by  => $test_loginid,
        length      => 6,
        alphabet    => ['0' .. '9'],
    );

    my $former_token = $token->token;

    ok $token->token =~ /\d{6}/, 'Expected a 6 digit token';

    $token = BOM::Platform::Token->new(
        email       => $email,
        created_for => 'phone_number_verification',
        created_by  => $test_loginid,
        length      => 6,
        alphabet    => [0 .. 9],
    );

    ok $token->token =~ /\d{6}/, 'Expected a 6 digit token';
    is $token->validate_token(), 1,                           'Token is valid';
    is $token->{created_for},    'phone_number_verification', 'Token is valid, got correct created_for';

    ok !BOM::Config::Redis::redis_replicated_write()->get('VERIFICATION_TOKEN::' . $former_token), 'The former token is gone';
};

done_testing();
