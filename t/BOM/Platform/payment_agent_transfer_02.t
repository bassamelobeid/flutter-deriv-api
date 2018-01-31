#!perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use Client::Account;
use Client::Account::Payments;
use Client::Account::PaymentAgent;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $pa        = Client::Account::PaymentAgent->new({loginid => 'CR0020'});
my $pa_client = $pa->client;
my $client    = Client::Account->new({loginid => 'CR0021'});

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
        toClient     => $pa_client,
        currency     => 'USD',
        amount       => 1000,
        fees         => 0,
        gateway_code => 'payment_agent_transfer'
    );

    $pa_client->payment_account_transfer(
        toClient     => $client,
        currency     => 'USD',
        amount       => 1000,
        fees         => 0,
        gateway_code => 'payment_agent_transfer'
    );
    $pa_total_amount =
        $clientdb->getall_arrayref('select * from payment_v1.get_today_client_payment_agent_transfer_total_amount(?)', [$pa_client->loginid])->[0]
        ->{amount};
    is($pa_total_amount + 0, 2000, "payment agent transfer total amount is correct");
};

subtest 'PA withdrawal with long further instructions by client' => sub {
    # for payment.payment table, remark field length is VARCHAR(800)
    lives_ok {
        my $remark;
        $remark .= 'x' x 800;

        # note amount must differ from 1000 here to avoid BI102
        $client->payment_account_transfer(
            toClient     => $pa_client,
            currency     => 'USD',
            amount       => 999,
            remark       => $remark,
            fees         => 0,
            gateway_code => 'payment_agent_transfer'
        );
    }
    "OK with remark length = 800";

    select undef, undef, undef, 2.1;    # avoid BI102
    throws_ok {
        my $remark;
        $remark .= 'x' x 801;

        $client->payment_account_transfer(
            toClient     => $pa_client,
            currency     => 'USD',
            amount       => 999,
            remark       => $remark,
            fees         => 0,
            gateway_code => 'payment_agent_transfer'
        );
    }
    qr/value too long for type character varying\(800\)/, 'remark length cannot > 800';
};

done_testing();
