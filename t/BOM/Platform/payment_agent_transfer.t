use strict;
use warnings;
use Test::More tests => 4;
use Test::NoWarnings;
use Test::Exception;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

use Test::MockModule;
use DateTime;

my ($client, $pa_client);
my ($client_account, $pa_account);

my ($client_datamapper, $pa_datamapper);
my ($total_withdrawal, $withdrawal_count);

my $transfer_amount = 2000.2525;
my $transfer_amount_2dp = sprintf('%.2f', $transfer_amount);

subtest 'Initialization' => sub {
    plan tests => 1;

    lives_ok {
        $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $client_account = $client->set_default_account('USD');

        $client->payment_free_gift(
            currency => 'USD',
            amount   => 5000,
            remark   => 'free gift',
        );

        $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $pa_account = $pa_client->set_default_account('USD');

        # make him a payment agent, this will turn the transfer into a paymentagent transfer.
        $pa_client->payment_agent({
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
        $pa_client->save;
    }
    'Initial accounts to test deposit & withdrawal via PA';
};

subtest 'Client withdraw money via payment agent' => sub {
    plan tests => 7;

    lives_ok {
        transfer_from_client_to_pa();
    }
    'Client withdrawal: client transfer money to payment agent';

    lives_ok {
        $pa_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $pa_client->loginid,
            currency_code  => 'USD',
        });

        ($total_withdrawal, $withdrawal_count) = $pa_datamapper->get_today_payment_agent_withdrawal_sum_count();
    }
    'PA get_today_payment_agent_withdrawal_sum_count';

    cmp_ok($total_withdrawal, '==', '0', 'PA withdrawal amount');
    cmp_ok($withdrawal_count, '==', '0', 'PA withdrawal count');

    lives_ok {
        $client_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({
            client_loginid => $client->loginid,
            currency_code  => 'USD',
        });

        ($total_withdrawal, $withdrawal_count) = $client_datamapper->get_today_payment_agent_withdrawal_sum_count();
    }
    'Client get_today_payment_agent_withdrawal_sum_count';

    cmp_ok($total_withdrawal, 'eq', $transfer_amount_2dp, 'Client withdrawal amount, 2 digits rounded');
    cmp_ok($withdrawal_count, '==', 1, 'Client withdrawal count');
};

sub transfer_from_client_to_pa {
    # Always ensure that PAYMENT AGENT always available
    my $dt_mocked = Test::MockModule->new('DateTime');
    $dt_mocked->mock('day_of_week', sub { return 2 });

    $client->validate_agent_payment(
        amount   => $transfer_amount,
        currency => $client_account->currency_code,
        toClient => $pa_client,
    );

    $client->payment_account_transfer(
        amount   => $transfer_amount,
        currency => $client_account->currency_code,
        toClient => $pa_client,
        remark   => 'Transfer from CR0010 to Payment Agent Paypal Transaction reference: #USD10#F72117379D1DD7B5# Timestamp: 22-Jul-11 08:36:49GMT',
    );
}

sub transfer_from_pa_to_client {
    # Always ensure that PAYMENT AGENT always available
    my $dt_mocked = Test::MockModule->new('DateTime');
    $dt_mocked->mock('day_of_week', sub { return 2 });

    $pa_client->validate_agent_payment(
        amount   => $transfer_amount,
        currency => $client_account->currency_code,
        toClient => $client,
    );

    $pa_client->payment_account_transfer(
        amount   => $transfer_amount,
        currency => $client_account->currency_code,
        toClient => $client,
        remark   => 'Transfer from Payment Agent to CR0010 Paypal Transaction reference: #USD10#F72117379D1DD7B5# Timestamp: 22-Jul-11 08:36:49GMT',
    );
}

