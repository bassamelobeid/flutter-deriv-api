use strict;
use warnings;

use Test::More;
use Test::MockModule;

use FindBin qw/ $Bin /;
use lib "$Bin/lib";

use APIHelper qw/ balance deposit request decode_json /;

# mock datadog
my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
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

    is $req->code,      201,                                  'Correct created status code';
    like $req->content, qr/<opt>\s*<data><\/data>\s*<\/opt>/, 'Correct content';

    my $current_balance = balance $loginid;
    is 0 + $current_balance, $start_balance + 1, 'Correct final balance';

    # Record transaction
    my $location = $req->header('location');
    ok $location, 'Request header location is present';

    $location =~ s/^(.*?)\/transaction/\/transaction/;
    $req = request 'GET', $location;

    my $body = decode_json $req->content;
    is $body->{client_loginid}, $loginid, "{client_loginid} is present and correct in response body";
    is $body->{type}, 'deposit', '{type} is present and correct in response body';
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
    my $trace_id = 987;
    my $txn_id   = 567876;

    deposit(
        loginid        => $loginid,
        trace_id       => $trace_id,
        transaction_id => $txn_id
    );

    my $current_balance = balance $loginid;

    my $req = deposit(
        loginid        => $loginid,
        trace_id       => $trace_id,
        transaction_id => $txn_id
    );

    is $req->code,      400,                                'Correct bad request status code';
    like $req->content, qr/Detected duplicate transaction/, 'Correspond error message to duplicate transaction';

    is balance($loginid), $current_balance, 'Correct unchanged balance';
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
        loginid           => $loginid,
        trace_id          => 1235,
        payment_processor => 'QIWI',
    );
    is $req->code, 201, 'Correct created status code';

    is $last_event{type}, 'payment_deposit', 'event payment_deposit emitted';
    is $last_event{data}->{payment_processor}, 'QIWI', 'event has correct payment_processor';
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

done_testing();
