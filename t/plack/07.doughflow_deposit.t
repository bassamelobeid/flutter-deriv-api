use strict;
use warnings;

use FindBin qw/ $Bin /;
use lib "$Bin/lib";

use Test::More;
use Test::MockModule;

use BOM::Database::DataMapper::Transaction;
use BOM::Database::ClientDB;
use BOM::User;
use BOM::User::Client;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);
use BOM::Test::Helper::Client                  qw(invalidate_object_cache);

use APIHelper   qw/ balance deposit request decode_json /;
use Digest::SHA qw/sha256_hex/;

# mock datadog
my $mocked_datadog = Test::MockModule->new('BOM::API::Payment::Metric');
my @datadog_args;
$mocked_datadog->mock('stats_inc', sub { @datadog_args = @_ });

# prepare test env
my $loginid = 'CR0012';

my $client_db = BOM::Database::ClientDB->new({client_loginid => $loginid});
my $user      = BOM::User->create(
    email    => 'unit_test@binary.com',
    password => 'asdaiasda'
);
$user->add_loginid($loginid);

subtest 'Successful attempt' => sub {
    my $start_balance = balance $loginid;
    my $req           = deposit(
        loginid        => $loginid,
        trace_id       => 1234,
        transaction_id => 94575934,
    );

    is $req->code, 201, 'Correct created status code';
    like $req->content, qr/<opt>\s*<data><\/data>\s*<\/opt>/, 'Correct content';

    my $current_balance = balance $loginid;
    is 0 + $current_balance, $start_balance + 1, 'Correct final balance';

    # Record transaction
    my $location = $req->header('location');
    ok $location, 'Request header location is present';

    $location =~ s/^(.*?)\/transaction/\/transaction/;
    $req = request 'GET', $location;

    my $body = decode_json $req->content;
    is $body->{client_loginid}, $loginid,  "{client_loginid} is present and correct in response body";
    is $body->{type},           'deposit', '{type} is present and correct in response body';
};

subtest 'Wrong trace id' => sub {
    my $current_balance = balance $loginid;

    my $req = deposit(
        loginid  => $loginid,
        trace_id => ' -123',
    );

    is $req->code, 400, 'Correct bad request status code';
    like $req->content,
        qr/(Attribute \(trace_id\) does not pass the type constraint|trace_id must be a positive integer)/,
        'Correct error message about wrong {trace_id} in response body';

    is balance($loginid), $current_balance, 'Correct unchanged balance';
};

subtest 'Duplicate transaction' => sub {
    my $trace_id          = 987;
    my $txn_id            = 567876;
    my $payment_processor = 'Skrill';

    deposit(
        loginid           => $loginid,
        trace_id          => $trace_id,
        transaction_id    => $txn_id,
        payment_processor => $payment_processor,
    );

    my $current_balance = balance $loginid;

    my $req = deposit(
        loginid           => $loginid,
        trace_id          => $trace_id,
        transaction_id    => $txn_id,
        payment_processor => $payment_processor,
    );

    is $req->code, 400, 'Correct bad request status code';
    like $req->content, qr/Detected duplicate transaction/, 'Correspond error message to duplicate transaction';

    is balance($loginid), $current_balance, 'Correct unchanged balance';

    $req = deposit(
        loginid           => $loginid,
        trace_id          => $trace_id + 1,
        transaction_id    => $txn_id,
        payment_processor => 'QIWI',
    );

    is $req->code, 201, 'Same transaction_id for different payment_processor is not duplicate';
};

subtest 'emit payment_deposit' => sub {
    my %last_event;
    my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
    $mock_events->mock(
        'emit',
        sub {
            my ($type, $data) = @_;
            %last_event = (
                type => $type,
                data => $data
            );
        });

    my $req = deposit(
        loginid            => $loginid,
        trace_id           => 1235,
        payment_processor  => 'QIWI',
        payment_type       => 'DogeTypeThing',
        account_identifier => '1234**9999',
    );
    is $req->code, 201, 'Correct created status code';

    my $trx = $client_db->db->dbic->run(
        fixup => sub { $_->selectrow_hashref("SELECT * FROM transaction.transaction ORDER BY transaction_time DESC LIMIT 1", undef) });

    my $doughflow_payment = $client_db->db->dbic->run(
        fixup => sub {
            $_->selectrow_hashref('SELECT * FROM payment.doughflow ORDER BY payment_id DESC LIMIT 1');
        });

    is_deeply $doughflow_payment,
        {
        payment_type               => 'DogeTypeThing',
        payment_processor          => 'QIWI',
        created_by                 => 'derek',
        payment_id                 => $doughflow_payment->{payment_id},
        transaction_type           => 'deposit',
        ip_address                 => '127.0.0.1',
        trace_id                   => $doughflow_payment->{trace_id},
        payment_method             => 'VISA',
        transaction_id             => $doughflow_payment->{transaction_id},
        payment_account_identifier => undef,
        },
        'df payment is correct';

    is $last_event{type}, 'payment_deposit', 'event payment_deposit emitted';

    is_deeply $last_event{data},
        {
        loginid            => $loginid,
        payment_processor  => 'QIWI',
        transaction_id     => $trx->{id},
        is_first_deposit   => 0,
        trace_id           => 1235,
        amount             => '1',
        payment_fee        => '0',
        currency           => 'USD',
        payment_method     => 'VISA',
        payment_type       => 'DogeTypeThing',
        account_identifier => sha256_hex('1234**9999'),
        },
        'event args are correct';
};

subtest 'datadog metric collected' => sub {
    like($datadog_args[0], qr/bom.paymentapi.doughflow.deposit.success/, 'datadog collected metrics');
};

subtest 'payment params' => sub {

    my %params = (
        trace_id          => 1236,
        transaction_id    => int(rand(999999)),
        payment_processor => 'NuTeller',
        payment_method    => 'Bananas',
    );

    deposit(
        loginid => $loginid,
        %params
    );

    my $res = $client_db->db->dbic->dbh->selectrow_hashref(
        qq/select p.remark, d.*
        from payment.doughflow d 
        join payment.payment p on p.id = d.payment_id and p.payment_gateway_code = 'doughflow'
        where d.trace_id = $params{trace_id};/
    );

    for my $k (keys %params) {
        like $res->{remark}, qr/$k=$params{$k}/, "$k in remark";
        is $res->{$k}, $params{$k}, "$k saved in doughflow table";
    }
};

subtest 'skip deposit validation' => sub {

    BOM::User::Client->new({loginid => $loginid})->status->set('cashier_locked', 'system', 'testing');

    my $req = deposit(
        loginid => $loginid,
    );

    is $req->code, 201, 'Successful deposit even when cashier_locked';
};

subtest 'PA withdrawal is disabled on deposit' => sub {
    my $email = 'paymenti-api-test1@deriv.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'asdaiasda'
    );
    my $cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        binary_user_id => $user->id,
        broker_code    => 'CR',
        email          => $email,
        residence      => 'id',
    });
    my $cli_sib = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        binary_user_id => $user->id,
        broker_code    => 'CR',
        email          => $email,
        residence      => 'id',
    });

    $user->add_loginid($cli->loginid);
    $user->add_loginid($cli_sib->loginid);

    $cli->status->set('pa_withdrawal_explicitly_allowed', 'system', 'enable withdrawal through payment agent');
    $cli_sib->status->set('pa_withdrawal_explicitly_allowed', 'system', 'enable withdrawal through payment agent');

    my $start_balance = balance $cli->loginid;
    my $req           = deposit(
        loginid        => $cli->loginid,
        trace_id       => 1237,
        transaction_id => 94575935,
    );

    is $req->code, 201, 'Correct created status code';
    like $req->content, qr/<opt>\s*<data><\/data>\s*<\/opt>/, 'Correct content';

    my $current_balance = balance $cli->loginid;
    is 0 + $current_balance, $start_balance + 1, 'Correct final balance';

    # Record transaction
    my $location = $req->header('location');
    ok $location, 'Request header location is present';

    $location =~ s/^(.*?)\/transaction/\/transaction/;
    $req = request 'GET', $location;

    my $body = decode_json $req->content;
    is $body->{client_loginid}, $cli->loginid, "{client_loginid} is present and correct in response body";
    is $body->{type},           'deposit',     '{type} is present and correct in response body';

    ok !BOM::User::Client->new({loginid => $cli->loginid})->status->pa_withdrawal_explicitly_allowed,
        'PA witdrawal status was removed from client account';
    ok !BOM::User::Client->new({loginid => $cli_sib->loginid})->status->pa_withdrawal_explicitly_allowed,
        'PA witdrawal status was removed from siblings accounts';
};

subtest 'Deposit currency mismatch' => sub {
    my $email = 'theclient@deriv.com';
    my $user  = BOM::User->create(
        email    => $email,
        password => 'asdf1234'
    );
    my $cli = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        binary_user_id => $user->id,
        broker_code    => 'CR',
        email          => $email,
        residence      => 'ar'
    });

    $user->add_client($cli);
    $cli->account('USD');
    $cli = BOM::User::Client->new({loginid => $cli->loginid});

    ok !$cli->status->deposit_attempt, 'Client initially have no deposit_attempt status';

    $cli->status->set('deposit_attempt', 'SYSTEM', 'Simulate a deposit attempt');

    invalidate_object_cache($cli);

    ok $cli->status->deposit_attempt, 'Client has deposit_attempt status';

    my $req = deposit(
        loginid        => $cli->loginid,
        trace_id       => 12345,
        transaction_id => 94575934,
        currency_code  => 'EUR'            #attempt to deposit with different currency
    );

    is $req->code, 400, 'Bad request is thrown for deposit currency mismatch';
    like $req->content, qr/Deposit currency mismatch, client account is in USD, but the deposit is in EUR/, 'Describe the currency mismatch found';

    invalidate_object_cache($cli);
    ok $cli->status->deposit_attempt, 'Client has deposit_attempt status yet, even if deposit failed';

    $req = deposit(
        loginid        => $cli->loginid,
        trace_id       => 33456,
        transaction_id => 94573512,
        currency_code  => 'USD'            # now using the right currency
    );

    is $req->code, 201, 'Deposit with correct currency succeed';

    invalidate_object_cache($cli);

    ok !$cli->status->deposit_attempt, 'The status was removed after successful deposit';

};

done_testing();
