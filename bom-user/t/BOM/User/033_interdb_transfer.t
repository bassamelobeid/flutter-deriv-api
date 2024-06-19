use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use Test::Warnings                             qw(:all);
use JSON::MaybeUTF8                            qw(:v1);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client;
use BOM::User::InterDBTransfer;
use BOM::User::Script::InterDBTransferMonitor;

my $user = BOM::User->create(
    email    => 'test@deriv.com',
    password => 'x',
);

my $emitted_events;
my $mock_events = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock(emit => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

my $mock_transfer = Test::MockModule->new('BOM::User::InterDBTransfer');

subtest 'rpc transfers' => sub {

    my $client_ust = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
    $client_ust->account('UST');
    my $client_usd = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    $client_usd->account('USD');

    $user->add_client($_) for ($client_ust, $client_usd);
    BOM::Test::Helper::Client::top_up($client_ust, 'UST', 100);

    subtest 'successful transfer' => sub {

        my $res = $client_ust->payment_account_transfer(
            inter_db_transfer => 1,
            toClient          => $client_usd,
            currency          => 'UST',
            amount            => 5,
            to_amount         => 6,
            fees              => 0.01,
            source            => 123,
            txn_details       => {abc => 'xyz'},
        );

        cmp_ok $client_ust->account->balance, '==', 95, 'source account debited';
        cmp_ok $client_usd->account->balance, '==', 6,  'destination account credited';
        like $res->{transaction_id}, qr/\d+/, 'transaction id returned';

        cmp_deeply(
            $emitted_events,
            {
                'transfer_between_accounts' => [{
                        loginid    => $client_ust->loginid,
                        properties => {
                            fees               => num(0.01),
                            from_account       => $client_ust->loginid,
                            from_amount        => num(5),
                            from_currency      => 'UST',
                            gateway_code       => 'account_transfer',
                            id                 => $res->{transaction_id},
                            is_from_account_pa => 0,
                            is_to_account_pa   => 0,
                            source             => 123,
                            time               => ignore(),
                            to_account         => $client_usd->loginid,
                            to_amount          => num(6),
                            to_currency        => 'USD'
                        }}]
            },
            'transfer_between_accounts event emitted'
        );

        cmp_deeply(
            $client_ust->db->dbic->dbh->selectall_arrayref('select * from payment.account_transfer', {Slice => {}}),
            bag({
                    payment_id               => re('\d+'),
                    corresponding_db         => 'CR',
                    corresponding_payment_id => re('\d+'),
                    corresponding_currency   => 'USD'
                },
                {
                    payment_id               => re('\d+'),
                    corresponding_db         => 'CRW',
                    corresponding_payment_id => re('\d+'),
                    corresponding_currency   => 'UST',
                }
            ),
            '2 account_transfer records created'
        );
    };

    my %params = (
        from_dbic            => $client_ust->db->dbic,
        from_db              => $client_ust->broker_code,
        from_account_id      => $client_ust->account->id,
        from_currency        => 'UST',
        from_amount          => -1,
        from_staff           => 'x',
        from_remark          => 'x',
        to_db                => $client_usd->broker_code,
        to_dbic              => $client_usd->db->dbic,
        to_account_id        => $client_usd->account->id,
        to_currency          => 'USD',
        to_amount            => 1,
        to_staff             => 'x',
        to_remark            => 'x',
        payment_gateway_code => 'account_transfer',
        source               => 1,
    );

    subtest 'send error' => sub {
        cmp_deeply(
            exception {
                BOM::User::InterDBTransfer::transfer(%params, from_amount => -10000)
            },
            ['BI101', 'ERROR:  Insufficient account balance'],
            'raw error returned for insufficient balance in sending account'
        );

        cmp_ok $client_ust->account->balance, '==', 95, 'source account unchanged';
        cmp_ok $client_usd->account->balance, '==', 6,  'destination account unchanged';
    };

    subtest 'receive error' => sub {
        $mock_transfer->redefine(do_receive => sub { die });

        cmp_deeply(
            exception {
                BOM::User::InterDBTransfer::transfer(%params)
            },
            {
                error_code => 'TransferReceiveFailed',
                params     => ['1.00', 'UST']
            },
            'error for failed second transaction'
        );

        $mock_transfer->unmock_all;
        cmp_ok $client_ust->account->balance, '==', 94, 'source account debited';
        cmp_ok $client_usd->account->balance, '==', 6,  'destination account unchanged';
    };

    subtest 'receiving account currency changed (very unlikely)' => sub {
        cmp_deeply(
            exception {
                BOM::User::InterDBTransfer::transfer(%params, to_currency => 'EUR')
            },
            {error_code => 'TransferReverted'},
            'error for wrong destination account currency'
        );

        cmp_ok $client_ust->account->balance, '==', 94, 'source account unchanged';
        cmp_ok $client_usd->account->balance, '==', 6,  'destination account unchanged';
    };

    subtest 'both accounts currency changed (astronomically unlikely)' => sub {
        $mock_transfer->redefine(do_revert => sub { my %args = @_; $args{from_currency} = 'BTC'; $mock_transfer->original('do_revert')->(%args); });

        cmp_deeply(
            exception {
                BOM::User::InterDBTransfer::transfer(%params, to_currency => 'EUR')
            },
            {error_code => 'TransferRevertFailed'},
            'error for failed revert'
        );

        cmp_ok $client_ust->account->balance, '==', 93, 'source account debited';
        cmp_ok $client_usd->account->balance, '==', 6,  'destination account unchanged';

        $mock_transfer->unmock_all;
    };

    # reset outbox for following tests
    $client_usd->db->dbic->dbh->do("update payment.interdb_outgoing set status = 'COMPLETE'");
};

subtest script => sub {

    my $client_cr  = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
    my $client_crw = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CRW'});
    $_->account('USD')    for ($client_crw, $client_cr);
    $user->add_client($_) for ($client_crw, $client_cr);
    BOM::Test::Helper::Client::top_up($client_crw, $client_crw->currency, 100);

    my $mock_script = Test::MockModule->new('BOM::User::Script::InterDBTransferMonitor');
    $mock_script->redefine(BROKER_CODES => ['CRW']);  # in test db all brokers are in the same db so there's no point for the script to check them all
    $mock_script->redefine(PENDING_PROCESS_DELAY => 0);

    my %params = (
        from_dbic            => $client_crw->db->dbic,
        from_db              => 'CRW',
        from_account_id      => $client_crw->account->id,
        from_currency        => $client_crw->currency,
        from_amount          => -10,
        from_fees            => 0.01,
        from_staff           => 'bob',
        from_remark          => 'transfer from bob to sue',
        to_db                => 'CR',
        to_account_id        => $client_cr->account->id,
        to_currency          => $client_cr->currency,
        to_amount            => 11,
        to_staff             => 'sue',
        to_remark            => 'transfer to sue from bob',
        payment_gateway_code => 'account_transfer',
        source               => 99,
        details              => encode_json_text({k1 => 'v1', k2 => 'v2'}));

    subtest 'successful receive' => sub {

        my $res = BOM::User::InterDBTransfer::do_send(%params);

        cmp_ok $client_crw->account->balance, '==', 90, 'source account debited';

        BOM::User::Script::InterDBTransferMonitor->new->process;

        cmp_ok $client_cr->account->balance, '==', 11, 'destination account credited';

        is $client_crw->db->dbic->dbh->selectrow_array(
            "select status from payment.interdb_outgoing where source_db = 'CRW' AND source_payment_id = $res->{payment_id}"), 'COMPLETE',
            'outbox status in source is COMPLETE';

        BOM::User::Script::InterDBTransferMonitor->new->process;
        cmp_ok $client_crw->account->balance, '==', 90, 'source account not double debited on next run';
        cmp_ok $client_cr->account->balance,  '==', 11, 'destination account not double credited on next run';

        # simulate a outbox duplicate that could result from a race condition
        $client_crw->db->dbic->dbh->do(
            "update payment.interdb_outgoing set status = 'PENDING' where source_db = 'CRW' AND source_payment_id = $res->{payment_id}");

        # db function returns an error so a warning is generated
        warnings { BOM::User::Script::InterDBTransferMonitor->new->process };
        cmp_ok $client_crw->account->balance, '==', 90, 'source account not double debited on next run';
        cmp_ok $client_cr->account->balance,  '==', 11, 'destination account not double credited on next run';

        $client_crw->db->dbic->dbh->do(
            "update payment.interdb_outgoing set status = 'COMPLETE' where source_db = 'CRW' AND source_payment_id = $res->{payment_id}");
    };

    # reset balances
    BOM::Test::Helper::Client::top_up($client_crw, $client_crw->currency, 10);
    BOM::Test::Helper::Client::top_up($client_cr,  $client_cr->currency,  -11);

    subtest 'revert due to receiving account currency changed' => sub {

        my $res = BOM::User::InterDBTransfer::do_send(
            %params,
            from_amount => -1,
            to_currency => 'EUR'
        );

        BOM::User::Script::InterDBTransferMonitor->new->process;
        cmp_ok $client_crw->account->balance, '==', 100, 'source account unchanged after revert';
        cmp_ok $client_cr->account->balance,  '==', 0,   'destination account not credited';
        is $client_crw->db->dbic->dbh->selectrow_array(
            "select status from payment.interdb_outgoing where source_db = 'CRW' AND source_payment_id = $res->{payment_id}"), 'REVERTED',
            'outbox status in source is REVERTED';

        is $client_cr->db->dbic->dbh->selectrow_array(
            "select status from payment.interdb_outgoing where source_db = 'CRW_REVERT' AND source_payment_id = $res->{payment_id}"),
            'REVERTED', 'outbox status in destination is REVERTED';

        BOM::User::Script::InterDBTransferMonitor->new->process;
        cmp_ok $client_crw->account->balance, '==', 100, 'source account unchanged on next run';
        cmp_ok $client_cr->account->balance,  '==', 0,   'destination account unchanged on next run';
    };

    subtest 'revert due to both accounts currencies changed' => sub {

        my $res = BOM::User::InterDBTransfer::do_send(
            %params,
            from_amount => -1,
            to_currency => 'EUR'
        );

        # simulate currency changed in sending account
        $client_crw->db->dbic->dbh->do(
            "update payment.interdb_outgoing set source_currency = 'EUR' where source_db = 'CRW' AND source_payment_id = $res->{payment_id}");

        BOM::User::Script::InterDBTransferMonitor->new->process,

            cmp_ok $client_crw->account->balance, '==', 99, 'source account was not credited back';
        cmp_ok $client_cr->account->balance, '==', 0, 'destination account not credited';
        is $client_crw->db->dbic->dbh->selectrow_array(
            "select status from payment.interdb_outgoing where source_db = 'CRW' AND source_payment_id = $res->{payment_id}"),
            'MANUAL_INTERVENTION_REQUIRED', 'outbox status in source is MANUAL_INTERVENTION_REQUIRED';

        is $client_cr->db->dbic->dbh->selectrow_array(
            "select status from payment.interdb_outgoing where source_db = 'CRW_REVERT' AND source_payment_id = $res->{payment_id}"),
            'MANUAL_INTERVENTION_REQUIRED', 'outbox status in destination is MANUAL_INTERVENTION_REQUIRED';

        BOM::User::Script::InterDBTransferMonitor->new->process;
        cmp_ok $client_crw->account->balance, '==', 99, 'source account unchanged after next run';
        cmp_ok $client_cr->account->balance,  '==', 0,  'destination account unchanged after next run';
    };

    # reset balances
    BOM::Test::Helper::Client::top_up($client_crw, $client_crw->currency, 1);

    subtest 'reprocess failed reversion' => sub {

        my $res = BOM::User::InterDBTransfer::do_send(
            %params,
            from_amount => -1,
            to_currency => 'EUR'
        );

        # simulate source db going offline
        my $mock_transfer = Test::MockModule->new('BOM::User::InterDBTransfer');
        $mock_transfer->redefine(do_revert => sub { die });

        BOM::User::Script::InterDBTransferMonitor->new->process;

        # this now leaves source outbox = PENDING, receiving outbox = REVERTING
        cmp_ok $client_crw->account->balance, '==', 99, 'source account not credited back yet';

        $mock_transfer->unmock_all;

        BOM::User::Script::InterDBTransferMonitor->new->process;
        cmp_ok $client_crw->account->balance, '==', 100, 'source account credited back on next run';

    };
};

done_testing();

