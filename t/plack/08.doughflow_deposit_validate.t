use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance deposit_validate);
use Encode;
use JSON::MaybeXS;

my $loginid = 'CR0011';

my $client_db = BOM::Database::ClientDB->new({client_loginid => $loginid});

my $user = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda'
);
$user->add_loginid($loginid);

my $starting_balance = balance($loginid);

my $r = deposit_validate(
    loginid => $loginid,
);
is($r->code,                                                                200,                   'correct status code');
is(JSON::MaybeXS->new->decode(Encode::decode_utf8($r->content))->{allowed}, 1,                     'validate pass');
is(0 + balance($loginid),                                                   $starting_balance + 0, 'balance is not changed.');

$r = deposit_validate(
    loginid => $loginid,
    amount  => 'Zzz',
);
my $resp = JSON::MaybeXS->new->decode(Encode::decode_utf8($r->content));
is $resp->{allowed},   0,                                                                                 'failed status';
like $resp->{message}, qr[(Attribute \(amount\) does not pass the type constraint|Invalid money amount)], 'Correct error message on response body';

subtest 'cashier validation' => sub {
    BOM::User::Client->new({loginid => $loginid})->status->set('cashier_locked', 'system', 'testing');

    my $req = deposit_validate(
        loginid => $loginid,
    );

    my $resp = JSON::MaybeXS->new->decode(Encode::decode_utf8($req->content));
    is $resp->{allowed}, 0,                         'validation fails when cashier_locked';
    is $resp->{message}, 'Your cashier is locked.', 'Correct error message in response body';
};

done_testing();
