use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use APIHelper       qw(request_json deposit_validate deposit withdrawal_validate create_payout update_payout record_failed_withdrawal);
use JSON::MaybeUTF8 qw(:v1);
use BOM::User::Client;
use Test::MockModule;

my $user = BOM::User->create(
    email    => 'test@deriv.com',
    password => 'x'
);

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CR',
    binary_user_id => $user->id,
});

my $wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code    => 'CRW',
    binary_user_id => $user->id,
    account_type   => 'doughflow',
});

for ($client, $wallet) {
    $user->add_client($_);
    $_->account('USD');
}

my $r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $client->loginid,
            currency_code  => 'USD',
            udef3          => $client->loginid,
        }));

is decode_json_utf8($r->content)->{client_loginid}, $client->loginid, 'undef3 for legacy account';

$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $wallet->doughflow_pin,
            currency_code  => 'USD',
            udef3          => $client->loginid,
        }));

is $r->content, 'Authorization required', 'error returned for client udef3 mismatch';

$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $client->doughflow_pin,
            currency_code  => 'USD',
            udef3          => $wallet->loginid,
        }));

is $r->content, 'Authorization required', 'error returned for wallet udef3 mismatch';

$wallet->set_doughflow_pin($client->loginid);
is $wallet->doughflow_pin, $client->loginid, 'wallet pin is mapped to client loginid';

$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $client->doughflow_pin,
            currency_code  => 'USD',
            udef3          => $client->loginid,
        }));

is $r->content, 'Authorization required', 'error returned for mapped client udef3 mismatch';

$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $client->loginid,
            currency_code  => 'USD',
            udef3          => $wallet->loginid,
        }));

is decode_json_utf8($r->content)->{client_loginid}, $wallet->loginid, 'correct udef3 for mapped wallet account';

# we should never be called by doughflow like this, but it will succeed for now
$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $wallet->loginid,
            currency_code  => 'USD',
            udef3          => $wallet->loginid,
        }));

is decode_json_utf8($r->content)->{client_loginid}, $wallet->loginid, 'wallet loginid itself as PIN';

$r = request_json(
    'GET',
    '/account',
    encode_json_utf8({
            client_loginid => $client->loginid,
            currency_code  => 'USD',
            udef3          => $wallet->loginid,
        }));

$r = deposit_validate(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'deposit_validate ok';

$r = deposit(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'deposit ok';

$r = withdrawal_validate(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'withdrawal_validate ok';

$r = create_payout(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'create_payout ok';

$r = update_payout(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'update_payout ok';

$r = record_failed_withdrawal(
    client_loginid => $client->loginid,
    udef3          => $wallet->loginid,
);
ok $r->is_success, 'record_failed_withdrawal ok';

done_testing();
