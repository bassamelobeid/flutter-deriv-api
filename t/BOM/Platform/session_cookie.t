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
ok($session_cookie->loginid, 'Second login works');
ok(! BOM::Platform::SessionCookie->new(token => $session_cookie->token)->token, 'cannot re-use first session cookie token');

throws_ok {
    my $lc = BOM::Platform::SessionCookie->new({
        loginid => $loginid,
    });
}
qr/email /, 'email parameter is mandatory';

my $value = $session_cookie2->token;
ok !BOM::Platform::SessionCookie->new(token => "${value}a")->token, "Couldn't create instance from invalid value";
my $session_cookie3 = BOM::Platform::SessionCookie->new(token => $value);
ok $session_cookie3->token,     "Created login cookie from value" or diag $value;
isa_ok $session_cookie3, 'BOM::Platform::SessionCookie';

my $session_cookie4 = BOM::Platform::SessionCookie->new(token => $value);
ok $session_cookie4, "Created login cookie from value";
cmp_deeply(
    $session_cookie4,
    methods(
        loginid => $loginid,
        token   => $value,
        email   => $email,
    ),
    "Correct values for all attributes",
) or diag Test::More::explain $session_cookie4;

subtest 'session generation is fork-safe', sub {
    my $c1 = BOM::Platform::SessionCookie->new(
        loginid => $loginid,
        email   => $email,
    )->token;
    note "c1 = $c1";
    my $pid = open my $fh, '-|';
    defined $pid or die "Cannot fork(): $!";
    unless ($pid) {             # child process
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
