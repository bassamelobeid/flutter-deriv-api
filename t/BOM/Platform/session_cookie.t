use Test::Most;
use Test::FailWarnings;
use BOM::Platform::SessionCookie;
use BOM::Platform::Context::Request;

my $loginid  = 'VRTC10001';
my $password = 'abc123';
my $email    = 'xyz@binary.com';

my $session_cookie = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email,
);
my $request = BOM::Platform::Context::Request->new(session_cookie => $session_cookie);

my $session_cookie2 = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email,
);
my $request2 = BOM::Platform::Context::Request->new(session_cookie => $session_cookie2);

throws_ok {
    my $lc = BOM::Platform::SessionCookie->new({
        loginid => $loginid,
    });
}
qr/email /, 'email parameter is mandatory';

my $value = $session_cookie->token;
ok !BOM::Platform::SessionCookie->new(token => "${value}a")->token, "Couldn't create instance from invalid value";
$session_cookie = BOM::Platform::SessionCookie->new(token => $value);
ok $session_cookie->token,     "Created login cookie from value" or diag $value;
isa_ok $session_cookie, 'BOM::Platform::SessionCookie';

$session_cookie = BOM::Platform::SessionCookie->new(token => $value);
ok $session_cookie, "Created login cookie from value";
cmp_deeply(
    $session_cookie,
    methods(
        loginid => $loginid,
        token   => $session_cookie->token,
        email   => $email,
    ),
    "Correct values for all attributes",
);

done_testing();
