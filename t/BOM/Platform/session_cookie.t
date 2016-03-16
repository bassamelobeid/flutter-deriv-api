use Test::Most;
use Test::FailWarnings;
use Digest::MD5 qw(md5_hex);

use BOM::Platform::SessionCookie;
use BOM::Platform::Context::Request;
use BOM::System::RedisReplicated;

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

my $session_cookie3 = BOM::Platform::SessionCookie->new(
    loginid => $loginid,
    email   => $email,
);

$session_cookie3->end_other_sessions();

my $all_session = BOM::System::RedisReplicated::redis_write()->smembers('LOGIN_SESSION_COLLECTION::' . md5_hex($email));
is scalar @$all_session, 1, 'Correct number of session in collection';
is $all_session->[0], $session_cookie3->token, 'Collection has only current token';

my $old_session = BOM::Platform::SessionCookie->new({token => $session_cookie->token});
is $old_session->token, undef, 'Cannot access old token';

$old_session = BOM::Platform::SessionCookie->new({token => $session_cookie2->token});
is $old_session->token, undef, 'Cannot access old token';

$session_cookie3->end_session();
$all_session = BOM::System::RedisReplicated::redis_write()->smembers('LOGIN_SESSION_COLLECTION::' . md5_hex($email));
is scalar @$all_session, 0, 'All session ended correctly';

$session_cookie3 = BOM::Platform::SessionCookie->new(
    loginid    => $loginid,
    email      => $email,
    expires_in => 1
);
ok $session_cookie3->token, 'token not expired yet';

# make sure token expires so sleeping
sleep(4);

$session_cookie3 = BOM::Platform::SessionCookie->new({token => $session_cookie3->token});
is $session_cookie3->token, undef, 'token already expired';

done_testing();
