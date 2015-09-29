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
my $pa_datamapper;

subtest 'Initialization' => sub {
    plan tests => 7;
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
        $pa_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $client_to->loginid,
            currency_code  => 'USD',
        });
    }
    'DataMapper for PA';

    my ($payment_sum, $payment_count) = $pa_datamapper->get_today_payment_agent_withdrawal_sum_count();
    cmp_ok($payment_count, '==', '0', 'PA - ' . $client_to->loginid . ' no PA withdrawal count for today');
    cmp_ok($payment_sum, '==', '0', 'PA - ' . $client_to->loginid . ' no PA withdrawal sum for today');

    lives_ok {
        $pa_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $client_from->loginid,
            currency_code  => 'USD',
        });
    }
    'DataMapper for client';

    ($payment_sum, $payment_count) = $pa_datamapper->get_today_payment_agent_withdrawal_sum_count();
    cmp_ok($payment_count, '==', '1', 'Client - ' . $client_from->loginid . ' PA withdrawal count for today');
};

subtest 'method actual tests' => sub {
    plan tests => 10;
    my ($total_withdrawal, $withdrawal_count);

    lives_ok {
        ($total_withdrawal, $withdrawal_count) = $pa_datamapper->get_today_payment_agent_withdrawal_sum_count();
    }
    'Expect to run get_today_payment_agent_withdrawal_sum_count';

    ok(defined $total_withdrawal, "Got valid number [$total_withdrawal]");
    is($total_withdrawal, sprintf("%.2f", $transfer_amount), 'Got correct amount as it was expected');

    my $two_d_rounded = sprintf("%.2f", $total_withdrawal);
    ok($total_withdrawal eq $two_d_rounded, "Correctly rounded [$total_withdrawal]");

    ok(defined $withdrawal_count, "Got valid number [$withdrawal_count]");

    my $deposit_count;
    lives_ok {
        deposit_transaction();
    }
    'payment agent makes deposit transaction';

    lives_ok {
        $deposit_count = $pa_datamapper->get_today_client_payment_agent_transfer_deposit_count();
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

