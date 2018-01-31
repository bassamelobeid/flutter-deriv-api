#!perl

use strict;
use warnings;
use Test::More tests => 3;
use Test::Exception;
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::ClientDB;

use Test::MockModule;
use DateTime;

my ($client,         $pa_client);
my ($client_account, $pa_account);

my ($clientdb,         $amount_data);
my ($total_withdrawal, $withdrawal_count);

my $transfer_amount = 2000.25;

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
    plan tests => 9;

    lives_ok {
        transfer_from_client_to_pa();
    }
    'Client withdrawal: client transfer money to payment agent';

    lives_ok {
        $clientdb = BOM::Database::ClientDB->new({
            client_loginid => $pa_client->loginid,
            operation      => 'replica',
        });
        $amount_data = $clientdb->getall_arrayref('select * from payment_v1.get_today_payment_agent_withdrawal_sum_count(?)', [$pa_client->loginid]);
        ($total_withdrawal, $withdrawal_count) = ($amount_data->[0]->{amount}, $amount_data->[0]->{count});
    }
    'PA get_today_payment_agent_withdrawal_sum_count';

    cmp_ok($total_withdrawal, '==', '0', 'PA withdrawal amount');
    cmp_ok($withdrawal_count, '==', '0', 'PA withdrawal count');

    lives_ok {
        $clientdb = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
            operation      => 'replica',
        });
        $amount_data = $clientdb->getall_arrayref('select * from payment_v1.get_today_payment_agent_withdrawal_sum_count(?)', [$client->loginid]);
        ($total_withdrawal, $withdrawal_count) = ($amount_data->[0]->{amount}, $amount_data->[0]->{count});
    }
    'Client get_today_payment_agent_withdrawal_sum_count';

    cmp_ok($total_withdrawal, 'eq', $transfer_amount, 'Client withdrawal amount, 2 digits rounded');
    cmp_ok($withdrawal_count, '==', 1, 'Client withdrawal count');

    throws_ok {
        transfer_from_client_to_pa();
    }
    qr/BI102\b.*?\blast transfer happened less than 2 seconds ago, this probably is a duplicate transfer/,
        'Client withdrawal: do it again -- should fail due to duplicated transfer';

    select undef, undef, undef, 2.1;    # sleep over the BI102 period
    lives_ok {
        transfer_from_client_to_pa();
    }
    'Client withdrawal: do it again -- should succeed after more than 2 sec.';

};

sub transfer_from_client_to_pa {
    # Always ensure that PAYMENT AGENT always available
    my $dt_mocked = Test::MockModule->new('DateTime');
    $dt_mocked->mock('day_of_week', sub { return 2 });

    $client->payment_account_transfer(
        amount   => $transfer_amount,
        currency => $client_account->currency_code,
        toClient => $pa_client,
        remark   => 'Transfer from CR0010 to Payment Agent Paypal Transaction reference: #USD10#F72117379D1DD7B5# Timestamp: 22-Jul-11 08:36:49GMT',
        fees     => 0,
        gateway_code => 'payment_agent_transfer'
    );
}

