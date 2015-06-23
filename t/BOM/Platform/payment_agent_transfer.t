use strict;
use warnings;
use Test::More tests => 3;
use Test::NoWarnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

use Test::MockModule;
use DateTime;

my $connection_builder;
my $account_from;
my $account_to;
my $client_from;
my $client_to;

my $transfer_amount = 2000.2525;
my $payment_agent_transfer_datamapper;

subtest 'Initialization' => sub {
    plan tests => 6;
    lives_ok {
        $connection_builder = BOM::Database::ClientDB->new({
            broker_code => 'CR',
        });

        $client_from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $account_from = $client_from->set_default_account('USD');

        $client_from->payment_free_gift(
            currency => 'USD',
            amount   => 5000,
            remark   => 'free gift',
        );

        $client_to = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $account_to = $client_to->set_default_account('USD');

        # make him a payment agent, this will turn the transfer into a paymentagent transfer.
        $client_to->payment_agent({
            payment_agent_name    => 'Joe',
            url                   => '',
            email                 => '',
            phone                 => '',
            information           => '',
            summary               => '',
            commission_deposit    => 0,
            commission_withdrawal => 0,
            is_authenticated      => 't',
            currency_code         => 'USD',
            currency_code_2       => 'USD',
            target_country        => 'au',
        });
        $client_to->save;

    }
    'Initial accounts to test payment_agent_transfer stuff';

    lives_ok {
        insert_payment_agent_transfer_transaction();
    }
    'Expect to insert payment agent transfer transaction';

    lives_ok {
        $payment_agent_transfer_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $client_to->loginid,
            currency_code  => 'USD',
        });
    }
    'Successfully create new PaymentAgentTransfer object';
    my $payments_record = $payment_agent_transfer_datamapper->get_payment_agent_withdrawal_txn_by_date(Date::Utility->new);
    cmp_ok(scalar @{$payments_record}, '==', '0', 'client ' . $client_to->loginid . ' has no transaction for date: ' . Date::Utility->new->date);

    lives_ok {
        $payment_agent_transfer_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $client_from->loginid,
            currency_code  => 'USD',
        });
    }
    'Successfully create new PaymentAgentTransfer object';

    $payments_record = $payment_agent_transfer_datamapper->get_payment_agent_withdrawal_txn_by_date(Date::Utility->new);
    cmp_ok(scalar @{$payments_record}, '==', '1', 'one transaction for date: ' . Date::Utility->new->date);

};

subtest 'method actual tests' => sub {
    plan tests => 11;
    my $total_withdrawal;
    lives_ok {
        $total_withdrawal = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_total_withdrawal();
    }
    'Expect to run get_today_client_payment_agent_transfer_total_withdrawal';

    ok(defined $total_withdrawal, "Got valid number [$total_withdrawal]");
    is($total_withdrawal, sprintf("%.2f", $transfer_amount), 'Got correct amount as it was expected');
    my $two_d_rounded = sprintf("%.2f", $total_withdrawal);
    ok($total_withdrawal eq $two_d_rounded, "Correctly rounded [$total_withdrawal]");

    my $withdrawal_count;
    lives_ok {
        $withdrawal_count = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_withdrawal_count();
    }
    'Expect to run get_today_client_payment_agent_transfer_withdrawal_count';

    ok(defined $withdrawal_count, "Got valid number [$withdrawal_count]");

    my $deposit_count;
    lives_ok {
        deposit_transaction();
    }
    'payment agent makes deposit transaction';

    lives_ok {
        $deposit_count = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_deposit_count();
    }
    'Expect to run get_today_client_payment_agent_transfer_deposit_count';

    ok(defined $deposit_count, "Got valid number [$deposit_count]");

    throws_ok {
        $transfer_amount = 2501;
        # Should throw limit error
        deposit_transaction();
    }
    qr/The maximum amount allowed for this transaction is USD 2500/;

    ok(defined $deposit_count, "Got valid number [$deposit_count]");

};

sub insert_payment_agent_transfer_transaction {

    bless $client_from, 'BOM::Platform::Client';
    bless $client_to,   'BOM::Platform::Client';

    # Always ensure that PAYMENT AGENT always available
    my $dt_mocked = Test::MockModule->new('DateTime');
    $dt_mocked->mock('day_of_week', sub { return 2 });

    $client_to->validate_agent_payment(
        amount   => $transfer_amount,
        currency => $account_from->currency_code,
        toClient => $client_to,
    );

    $client_from->payment_account_transfer(
        amount   => $transfer_amount,
        currency => $account_from->currency_code,
        toClient => $client_to,
        remark   => 'Transfer from CR0010 to Payment Agent Paypal Transaction reference: #USD10#F72117379D1DD7B5# Timestamp: 22-Jul-11 08:36:49GMT',
    );
}

sub deposit_transaction {

    bless $client_from, 'BOM::Platform::Client';
    bless $client_to,   'BOM::Platform::Client';

    # Always ensure that PAYMENT AGENT always available
    my $dt_mocked = Test::MockModule->new('DateTime');
    $dt_mocked->mock('day_of_week', sub { return 2 });

    $client_to->validate_agent_payment(
        amount   => $transfer_amount,
        currency => $account_from->currency_code,
        toClient => $client_from,
    );

    $client_to->payment_account_transfer(
        amount   => $transfer_amount,
        currency => $account_from->currency_code,
        toClient => $client_from,
        remark   => 'Transfer from Payment Agent to CR0010 Paypal Transaction reference: #USD10#F72117379D1DD7B5# Timestamp: 22-Jul-11 08:36:49GMT',
    );
}

