use strict;
use warnings;

use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(auth_request request decode_json);
use Digest::SHA;

my $loginid = 'CR0011';

my $r = request(
    'GET',
    '/session',
    {
        client_loginid => $loginid,
        currency_code  => 'USD'
    });
is $r->code, 401, 'session request fails if header-based auth already done';

$r = auth_request(
    'GET',
    '/session',
    {
        client_loginid => $loginid,
        currency_code  => 'USD'
    });
my $session = decode_json($r->content);
is $session->{loginid}, $loginid, 'session request accepts basic auth';
ok $session->{handoff_token_key},             '..and has a handoff token';
ok $session->{handoff_token_data}->{expires}, '..which expires';

$r = auth_request(
    'GET',
    '/session',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
        pass           => 'wrongpass'
    });
is $r->code, 401, 'rejects wrong password';

$r = request(
    'GET',
    '/session/validate',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
    });
is $r->code, 400, 'missing token is a bad validate request';
like $r->content, qr/Invalid or missing token in request/, '..and says why';

$r = request(
    'GET',
    '/session/validate',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
        token          => 'a' x 40,
    });
is $r->code, 400, 'bad token is a bad validate request';
like $r->content, qr/No token found/, '.. and says no token found';

$r = request(
    'GET',
    '/session/validate',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
        token          => $session->{handoff_token_key},
    });
is $r->code, 200, 'good token ok in validate request';
# {"status":"accepted","details":"http://127.0.0.1:50756/client/?loginid=CR170000"}
my $d = decode_json($r->content);
is $d->{status}, 'accepted', '.. with status accepted';
like $d->{details}, qr/loginid=$loginid/, ".. and echoes loginid $loginid";

subtest 'wallets' => sub {

    my $user = BOM::User->create(
        email    => 'session@test.com',
        password => 'xxx'
    );

    my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CRW',
        ,
        account_type    => 'doughflow',
        client_password => Digest::SHA::sha256_hex('xxx'),
        binary_user_id  => $user->id,
    });

    my $cr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => 'CR',
        binary_user_id => $user->id,
    });

    for ($wallet, $cr_client) {
        $_->account('USD');
        $user->add_client($_);
    }

    $wallet->set_doughflow_pin($cr_client->loginid);
    my $pin = $wallet->doughflow_pin;
    is $pin, $cr_client->loginid, 'pin is mapped';

    $r = auth_request(
        'GET',
        '/session',
        {
            client_loginid => $pin,
            currency_code  => 'USD',
            pass           => 'xxx',
        });

    my $session = decode_json($r->content);
    is $session->{loginid}, $pin, 'response loginid is set to mapped loginid';
    ok $session->{handoff_token_key},           'handoff token returned';
    ok $session->{handoff_token_data}{expires}, 'with expiry';

    $r = request(
        'GET',
        '/session/validate',
        {
            client_loginid => $pin,
            currency_code  => 'USD',
            token          => $session->{handoff_token_key},
        });

    is $r->code, 200, 'session/validate is successful';
    my $content = decode_json($r->content);
    is $content->{status}, 'accepted', 'status is accepted';
    like $content->{details}, qr/loginid=$pin/, 'details link contains pin';
};

done_testing();
