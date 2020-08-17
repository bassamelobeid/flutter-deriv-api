use strict;
use warnings;

use Test::More;

use FindBin qw/ $Bin /;
use lib "$Bin/lib";

use APIHelper qw/ balance deposit request decode_json withdraw/;

# prepare test env
my $loginid = 'CR0011';

my $client_db = BOM::Database::ClientDB->new({client_loginid => $loginid});
my $user = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda',
);
$user->add_loginid($loginid);

# Deposit initial amount
deposit(
    loginid => $loginid,
    amount  => 10
);

subtest 'Successful attempt' => sub {
    my $start_balance = balance $loginid;

    my $req = withdraw(
        loginid => $loginid,
        amount  => 1,
    );

    is $req->code, 201, 'Correct created status code';
    like $req->content, qr/<opt>\s*<data><\/data>\s*<\/opt>/, 'Correct response body';

    my $current_balance = balance $loginid;
    is 0 + $current_balance, $start_balance - 1, 'Correct final balance';

    # Record withdrawal
    my $location = $req->header('Location');
    ok($location);

    $location =~ s/^(.*?)\/transaction/\/transaction/;
    $req = request 'GET', $location;

    my $body = decode_json $req->content;
    is $body->{client_loginid}, $loginid, "{client_loginid} is present and correct in response body";
    is $body->{type}, 'withdrawal', '{type} is present and correct in response body';
};

subtest 'Wrong trace id' => sub {
    my $current_balance = balance $loginid;
    my $req             = withdraw(
        loginid  => $loginid,
        trace_id => ' -123',
    );

    is $req->code, 400, 'Correct bad request status code';
    like $req->content,
        qr/(Attribute \(trace_id\) does not pass the type constraint|trace_id must be a positive integer)/,
        'Correct error message in response body';

    is balance($loginid), $current_balance, 'Correct unchanged balance';
};

subtest 'Exceed balance' => sub {
    my $current_balance = balance $loginid;
    my $req             = withdraw(
        loginid => $loginid,
        amount  => $current_balance + 1000,
    );

    is $req->code, 403, 'Correct forbidden status code';
    like $req->decoded_content, qr/exceeds client balance/, 'Correspond error message to balance exceeding';
    is balance($loginid), $current_balance, 'Correct unchanged balance';
};

subtest 'Duplicate transaction' => sub {
    my $trace_id = 6588;

    withdraw(
        loginid  => $loginid,
        trace_id => $trace_id,
    );

    my $current_balance = balance $loginid;

    my $req = withdraw(
        loginid  => $loginid,
        trace_id => $trace_id,
    );

    is $req->code, 400, 'Correct bad request status code';
    like $req->content, qr/Detected duplicate transaction/, 'Correspond error message to duplicate transaction';

    is balance($loginid), $current_balance, 'Correct unchanged balance';
};

done_testing();
