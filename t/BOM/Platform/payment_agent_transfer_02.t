#!perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::Warnings 0.005 qw(:all);

use BOM::User::Client;
use BOM::User::Client::PaymentAgent;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $pa        = BOM::User::Client::PaymentAgent->new({loginid => 'CR0020'});
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

subtest 'is_agent_to_client params in transfer/withdrawal' => sub {
    dies_ok {
        $pa_client->payment_account_transfer(
            toClient     => $client,
            currency     => 'USD',
            amount       => 10,
            fees         => 0,
            gateway_code => 'payment_agent_transfer',
        );
    };

    is_deeply $@, ['BI201', 'ERROR:  Invalid payment agent loginid.'], 'Correct error code with no value (defaults to 0)';

    dies_ok {
        $pa_client->payment_account_transfer(
            toClient           => $client,
            currency           => 'USD',
            amount             => 10,
            fees               => 0,
            gateway_code       => 'payment_agent_transfer',
            is_agent_to_client => 0
        );
    }

    is_deeply $@, ['BI201', 'ERROR:  Invalid payment agent loginid.'], 'Correct error code when value is wrong (for payment agent to client)';
};

subtest 'PA withdrawal with long further instructions by client' => sub {
    # for payment.payment table, remark field length is VARCHAR(800)
    lives_ok {
        my $remark;
        $remark .= 'x' x 800;

        # note amount must differ from 1000 here to avoid BI102
        $client->payment_account_transfer(
            toClient           => $pa_client,
            currency           => 'USD',
            amount             => 999,
            remark             => $remark,
            fees               => 0,
            is_agent_to_client => 0,
            gateway_code       => 'payment_agent_transfer'
        );
    }
    "OK with remark length = 800";

    select undef, undef, undef, 2.1;    # avoid BI102
    throws_ok {
        my $remark;
        $remark .= 'x' x 801;
        # expect DB call here to emit errors as warnings as well as exceptions
        # https://github.com/regentmarkets/bom-postgres/blob/master/lib/BOM/Database/Rose/DB.pm#L68
        warning {
            $client->payment_account_transfer(
                toClient           => $pa_client,
                currency           => 'USD',
                amount             => 999,
                remark             => $remark,
                fees               => 0,
                is_agent_to_client => 0,
                gateway_code       => 'payment_agent_transfer'
                )
        };
    }
    qr/value too long for type character varying\(800\)/, 'remark length cannot > 800';
};

done_testing();
