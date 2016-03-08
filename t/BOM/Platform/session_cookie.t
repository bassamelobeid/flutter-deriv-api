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

throws_ok {
    my $lc = BOM::Platform::SessionCookie->new({
        loginid     => $loginid,
        email       => $email,
        created_for => 'verify_email'
    });
}
qr/contains keys:created_for that are outside allowed/, 'created_for is not allowed';

my $value = $session_cookie->token;
ok !BOM::Platform::SessionCookie->new(token => "${value}a")->token, "Couldn't create instance from invalid value";
$session_cookie = BOM::Platform::SessionCookie->new(token => $value);
ok $session_cookie->token, "Created login cookie from value" or diag $value;
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

subtest 'session generation is fork-safe', sub {
    my $c1 = BOM::Platform::SessionCookie->new(
        loginid => $loginid,
        email   => $email,
    )->token;
    note "c1 = $c1";
    my $pid = open my $fh, '-|';
    defined $pid or die "Cannot fork(): $!";
    unless ($pid) {    # child process
        print +BOM::Platform::SessionCookie->new(
            loginid => $loginid,
            email   => $email,
        )->token, "\n";
        exit 0;
    }
    my $c2 = readline $fh;
    chomp $c2;
    note "c2 = $c2";
    my $c3 = BOM::Platform::SessionCookie->new(
        loginid => $loginid,
        email   => $email,
    )->token;
    note "c3 = $c3";

    is length $_, 48, 'token length' for ($c1, $c2, $c3);
    isnt $c1, $c2, 'c1 <> c2';
    isnt $c1, $c3, 'c1 <> c3';
    isnt $c2, $c3, 'c2 <> c3';
};

done_testing();
