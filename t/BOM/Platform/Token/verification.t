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
done_testing();
