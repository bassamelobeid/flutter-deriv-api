use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use_ok('BOM::Database::DataMapper::Payment::PaymentAgentTransfer');

my $pa     = BOM::Platform::Client->new({loginid => 'CR0020'});
my $client = BOM::Platform::Client->new({loginid => 'CR0021'});

subtest 'get_today_client_payment_agent_transfer_total_amount' => sub {
    my $payment_agent_transfer_datamapper = BOM::Database::DataMapper::Payment::PaymentAgentTransfer->new({client_loginid => $pa->loginid});
    my $pa_total_amount = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_total_amount;
    is($pa_total_amount, 0);
    $client->payment_account_transfer(
        toClient => $pa,
        currency => 'USD',
        amount   => 1000
    );
    $pa->payment_account_transfer(
        toClient => $client,
        currency => 'USD',
        amount   => 1000
    );
    $pa_total_amount = $payment_agent_transfer_datamapper->get_today_client_payment_agent_transfer_total_amount;
    is($pa_total_amount + 0, 2000, "payment agent transfer total amount is correct");
};

done_testing();
