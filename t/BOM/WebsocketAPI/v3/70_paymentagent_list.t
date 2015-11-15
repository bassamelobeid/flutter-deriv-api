use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

my $t = build_mojo_test();

my ($client,         $pa_client);
my ($client_account, $pa_account);
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

# paymentagent_list
$t = $t->send_ok({json => {paymentagent_list => 'au'}})->message_ok;
my $res = decode_json($t->message->[1]);
ok(grep { $_->[0] eq 'au' } @{$res->{available_countries}});
ok(grep { $_->{name} eq 'Joe' } @{$res->{list}});
test_schema('paymentagent_list', $res);

$t->finish_ok;

done_testing();
