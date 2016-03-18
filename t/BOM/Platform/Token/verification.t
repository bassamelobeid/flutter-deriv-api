use Test::Most;
use Test::FailWarnings;

use BOM::Platform::Token::Verification;

my $loginid  = 'VRTC10001';
my $password = 'abc123';
my $email    = 'xyz@binary.com';

throws_ok {
    my $token = BOM::Platform::Token::Verification->new(email => $email);
}
qr/created_for /, 'created_for parameter is mandatory';

my $token = BOM::Platform::Token::Verification->new(
    email       => $email,
    created_for => 'verify_email'
);

ok $token->token, 'Token created successfully';

$token = BOM::Platform::Token::Verification->new({token => $token->token});
is $token->validate_token(), 1, 'Token is valid';
is $token->{created_for}, 'verify_email', 'Token is valid, got correct created_for';

ok $token->delete_token(), 'token deleted successfully';

$token = BOM::Platform::Token::Verification->new({token => $token->token});
is $token->token, undef, "Can't created token from already deleted one";

done_testing();
