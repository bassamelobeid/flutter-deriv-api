use Test::Most;
use Test::FailWarnings;
use BOM::Platform::SessionCookie;
use BOM::Utility::Crypt;
use BOM::Platform::Context::Request;

my $crypt = BOM::Utility::Crypt->new(keyname => 'cookie');

my $loginid  = 'VRTC10001';
my $password = 'abc123';
my $email    = 'xyz@binary.com';

my $session_cookie = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    token   => $password,
    email   => $email,
);
my $request = BOM::Platform::Context::Request->new(session_cookie => $session_cookie);

my $session_cookie2 = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    token   => $password,
    email   => $email,
);
my $request2 = BOM::Platform::Context::Request->new(session_cookie => $session_cookie2);

throws_ok {
    my $lc = BOM::Platform::SessionCookie->new({
        loginid => $loginid,
        email   => $email,
    });
}
qr/token/, 'Invalid combination of construction parameters.';

throws_ok {
    my $lc = BOM::Platform::SessionCookie->new({
        loginid => $loginid,
        token   => $password,
    });
}
qr/Attribute \(email\) is required at constructor/, 'email parameter is mandatory';

my $value = $session_cookie->token;
my $hash = $crypt->decrypt_payload(value => $value);
eq_or_diff $hash,
    {
    loginid => $loginid,
    token   => $password,
    email   => $email,
    },
    "Correctly encrypted cookie";

ok !BOM::Platform::SessionCookie->from_value("${value}a"), "Couldn't create instance from invalid value";
$session_cookie = BOM::Platform::SessionCookie->from_value($value);
ok $session_cookie,     "Created login cookie from value";
isa_ok $session_cookie, 'BOM::Platform::SessionCookie';

my $ref = {
    loginid => "VRTC666",
    token   => "abcdef",
    email   => 'abc@binary.com',
    clerk   => "nobody",
    expires => time - 60,
};
$value = $crypt->encrypt_payload(data => $ref);
ok !BOM::Platform::SessionCookie->from_value($value), "Couldn't build from expired cookie";
$ref->{expires} = time + 1000;
$value = $crypt->encrypt_payload(data => $ref);
$session_cookie = BOM::Platform::SessionCookie->from_value($value);
ok $session_cookie, "Created login cookie from value";
cmp_deeply(
    $session_cookie,
    methods(
        loginid => $ref->{loginid},
        token   => $ref->{token},
        email   => $ref->{email},
        clerk   => $ref->{clerk},
        expires => $ref->{expires},
    ),
    "Correct values for all attributes",
);

done_testing();
