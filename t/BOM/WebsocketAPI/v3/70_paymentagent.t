use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::Exception;

use BOM::Database::Model::AccessToken;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Transaction;
use BOM::Database::DataMapper::Payment::PaymentAgentTransfer;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });
my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

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
            amount   => 500,
            remark   => 'free gift',
        );

        $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
        });
        $pa_account = $pa_client->set_default_account('USD');

        # make him a payment agent, this will turn the transfer into a paymentagent transfer.
        $pa_client->payment_agent({
            payment_agent_name    => 'Joe',
            url                   => 'http://www.example.com/',
            email                 => 'joe@example.com',
            phone                 => '+12345678',
            information           => 'Test Info',
            summary               => 'Test Summary',
            commission_deposit    => 0,
            commission_withdrawal => 0,
            is_authenticated      => 't',
            currency_code         => 'USD',
            currency_code_2       => 'USD',
            target_country        => 'id',
        });
        $pa_client->save;
    }
    'Initial accounts to test deposit & withdrawal via PA';
};

# paymentagent_list
$t = $t->send_ok({json => {paymentagent_list => 'id'}})->message_ok;
my $res = decode_json($t->message->[1]);
ok(grep { $_->[0] eq 'id' } @{$res->{paymentagent_list}{available_countries}});
ok(grep { $_->{name} eq 'Joe' } @{$res->{paymentagent_list}{list}});
test_schema('paymentagent_list', $res);

my $token = BOM::Database::Model::AccessToken->new->create_token($client->loginid, 'Test Token');
$t = $t->send_ok({json => {authorize => $token}})->message_ok;

## paymentagent_withdraw
{
    $client = BOM::Platform::Client->new({loginid => $client->loginid});
    my $client_b_balance    = $client->default_account->balance;
    my $pa_client_b_balance = $pa_client->default_account->balance;

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{paymentagent_withdraw}, 1, 'paymentagent_withdraw ok';

    ## after withdraw, check both balance
    $client = BOM::Platform::Client->new({loginid => $client->loginid});
    ok $client->default_account->balance == $client_b_balance - 100, '- 100';
    $pa_client = BOM::Platform::Client->new({loginid => $pa_client->loginid});
    ok $pa_client->default_account->balance == $pa_client_b_balance + 100, '+ 100';

    ## test for failure
    foreach my $amount (undef, '', -1, 1, 2001) {
        $t = $t->send_ok({
                json => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    (defined $amount) ? (amount => $amount) : ()}})->message_ok;
        $res = decode_json($t->message->[1]);
        if (defined $amount and $amount ne '') {
            ok $res->{error}->{message} =~ /Invalid amount/, "test amount $amount";
        } else {
            ok $res->{error}->{message} =~ /Input validation failed: amount/, "test amount " . ($amount // 'undef');
        }
    }

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => 'VRTC000001',
                currency              => 'USD',
                amount                => 100
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /the Payment Agent does not exist/, 'the Payment Agent does not exist';

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'RMB',
                amount                => 100
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /your currency of USD is unavailable/, 'your currency of USD is unavailable';

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                description           => 'x' x 301
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{code} =~ /SanityCheckFailed/, 'Further instructions must not exceed';

    $client->set_status('withdrawal_locked', 'test.t', "just for test");
    $client->save();
    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /There was an error processing the request/, 'error';

    $client->clr_status('withdrawal_locked');
    $client->save();
    $pa_client->set_status('cashier_locked', 'test.t', 'just for test');
    $pa_client->save();
    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /This Payment Agent cashier section is locked/, 'This Payment Agent cashier section is locked';

    $pa_client->clr_status('cashier_locked');
    $pa_client->save();
    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 500,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /you cannot withdraw./, 'you cannot withdraw.';

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                dry_run               => 1,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{paymentagent_withdraw}, 2, 'paymentagent_withdraw dry_run ok';

    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /An error occurred while processing request/, 'An error occurred while processing request';

    # need unfreeze_client after withdraw error
    BOM::Platform::Transaction->unfreeze_client($client->loginid);
    BOM::Platform::Transaction->unfreeze_client($pa_client->loginid);
    $t = $t->send_ok({
            json => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{paymentagent_withdraw}, 1, 'paymentagent_withdraw ok again';
}

$t->finish_ok;

done_testing();
