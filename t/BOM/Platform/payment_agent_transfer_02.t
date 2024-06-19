#!perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Fatal;
use Test::Warnings 0.005 qw(:all);

use BOM::User::Client;
use BOM::User::Client::PaymentAgent;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $pa = BOM::User::Client::PaymentAgent->new({loginid => 'CR0020'});
$pa->status('authorized');
$pa->save;

my $pa_client = $pa->client;
my $client    = BOM::User::Client->new({loginid => 'CR0021'});

subtest 'get_today_client_payment_agent_transfer_total_amount' => sub {
    my $clientdb = BOM::Database::ClientDB->new({
        client_loginid => $pa_client->loginid,
        operation      => 'replica',
    });
    my $pa_total_amount =
        $clientdb->getall_arrayref('select * from payment_v1.get_today_client_payment_agent_transfer_total_amount(?)', [$pa_client->loginid])->[0]
        ->{amount};
    is($pa_total_amount, 0);

    $client->set_default_account('USD');
    $pa_client->set_default_account('USD');
    $client->payment_account_transfer(
        toClient           => $pa_client,
        currency           => 'USD',
        amount             => 1000,
        fees               => 0,
        is_agent_to_client => 0,
        gateway_code       => 'payment_agent_transfer'
    );

    $pa_client->payment_account_transfer(
        toClient           => $client,
        currency           => 'USD',
        amount             => 1000,
        fees               => 0,
        is_agent_to_client => 1,
        gateway_code       => 'payment_agent_transfer',
        verification       => 'paymentagent_transfer',
    );
    $pa_total_amount =
        $clientdb->getall_arrayref('select * from payment_v1.get_today_client_payment_agent_transfer_total_amount(?)', [$pa_client->loginid])->[0]
        ->{amount};
    is($pa_total_amount + 0, 2000, "payment agent transfer total amount is correct");
};

done_testing();
