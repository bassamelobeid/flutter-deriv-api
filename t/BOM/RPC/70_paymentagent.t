use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::MockModule;
use Data::Dumper;
use BOM::RPC::v3::Cashier;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Transaction;

my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });
my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

my ($client,         $pa_client);
my ($client_account, $pa_account);
{
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

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
$mock_utility->mock('token_to_loginid',            sub { return $client->loginid });
$mock_utility->mock('is_verification_token_valid', sub { return 1 });

# paymentagent_list
my $res = BOM::RPC::v3::Cashier::paymentagent_list({
        args => {
            paymentagent_list => 'id',
        }});
ok(grep { $_->[0] eq 'id' } @{$res->{available_countries}});
ok(grep { $_->{name} eq 'Joe' } @{$res->{list}});

## paymentagent_withdraw
{
    $client = BOM::Platform::Client->new({loginid => $client->loginid});
    my $client_b_balance    = $client->default_account->balance;
    my $pa_client_b_balance = $pa_client->default_account->balance;

    my $code = 'mocked';
    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    is $res->{status}, 1, 'paymentagent_withdraw ok';

    ## after withdraw, check both balance
    $client = BOM::Platform::Client->new({loginid => $client->loginid});
    ok $client->default_account->balance == $client_b_balance - 100, '- 100';
    $pa_client = BOM::Platform::Client->new({loginid => $pa_client->loginid});
    ok $pa_client->default_account->balance == $pa_client_b_balance + 100, '+ 100';

    ## test for failure
    foreach my $amount (-1, 1, 2001) {
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                token => 'blabla',
                args  => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    verification_code     => $code,
                    (defined $amount) ? (amount => $amount) : (),
                }});
        if (defined $amount and $amount ne '') {
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        } else {
            ok $res->{error}->{message_to_client} =~ /Input validation failed: amount/, "test amount " . ($amount // 'undef');
        }
    }

    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => 'VRTC000001',
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /the Payment Agent does not exist/, 'the Payment Agent does not exist';

    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'RMB',
                amount                => 100,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /your currency of USD is unavailable/, 'your currency of USD is unavailable';

    $client->set_status('withdrawal_locked', 'test.t', "just for test");
    $client->save();
    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /There was an error processing the request/, 'error';

    $client->clr_status('withdrawal_locked');
    $client->save();
    $pa_client->set_status('cashier_locked', 'test.t', 'just for test');
    $pa_client->save();
    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /This Payment Agent cashier section is locked/, 'This Payment Agent cashier section is locked';

    $pa_client->clr_status('cashier_locked');
    $pa_client->save();
    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 500,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /you cannot withdraw./, 'you cannot withdraw.';

    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                dry_run               => 1,
                verification_code     => $code
            }});
    is $res->{status}, 2, 'paymentagent_withdraw dry_run ok';

    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    ok $res->{error}->{message_to_client} =~ /An error occurred while processing request/, 'An error occurred while processing request';

    # need unfreeze_client after withdraw error
    BOM::Platform::Transaction->unfreeze_client($client->loginid);
    BOM::Platform::Transaction->unfreeze_client($pa_client->loginid);
    $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
            token => 'blabla',
            args  => {
                paymentagent_withdraw => 1,
                paymentagent_loginid  => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100,
                verification_code     => $code
            }});
    is $res->{status}, 1, 'paymentagent_withdraw ok again';
}

## transfer
{
    $pa_client = BOM::Platform::Client->new({loginid => $pa_client->loginid});
    $client    = BOM::Platform::Client->new({loginid => $client->loginid});
    my $client_b_balance    = $client->default_account->balance;
    my $pa_client_b_balance = $pa_client->default_account->balance;

    # from client to pa_client is not allowed
    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100
            }});
    ok $res->{error}->{message_to_client} =~ /You are not a Payment Agent/, 'You are not a Payment Agent';

    # login as pa_client
    $mock_utility->mock('token_to_loginid', sub { return $pa_client->loginid });

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100
            }});
    is $res->{status}, 1, 'paymentagent_transfer ok';

    ## after withdraw, check both balance
    $client = BOM::Platform::Client->new({loginid => $client->loginid});
    ok $client->default_account->balance == $client_b_balance + 100, '+ 100';
    $pa_client = BOM::Platform::Client->new({loginid => $pa_client->loginid});
    ok $pa_client->default_account->balance == $pa_client_b_balance - 100, '- 100';

    ## test for failure
    foreach my $amount (-1, 1, 2001) {
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                token => 'blabla',
                args  => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    (defined $amount) ? (amount => $amount) : (),
                }});
        if (defined $amount and $amount ne '') {
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        } else {
            ok $res->{error}->{message_to_client} =~ /Input validation failed: amount/, "test amount " . ($amount // 'undef');
        }
    }

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => 'VRTC000001',
                currency              => 'USD',
                amount                => 100
            }});
    ok $res->{error}->{message_to_client} =~ /Login ID \(VRTC000001\) does not exist/, 'Login ID (VRTC000001) does not exist';

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => 'OK992002',
                currency              => 'USD',
                amount                => 100,
                dry_run               => 1
            }});
    ok $res->{error}->{message_to_client} =~ /Login ID \(OK992002\) does not exist/, 'Login ID (VRTC000001) does not exist';

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'RMB',
                amount                => 100
            }});
    ok $res->{error}->{message_to_client} =~ /only USD is allowed/, 'only USD is allowed';

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $pa_client->loginid,
                currency              => 'USD',
                amount                => 100
            }});
    ok $res->{error}->{message_to_client} =~ /it is not allowed/, 'self, it is not allowed';

    $client->set_status('disabled', 'test.t', "just for test");
    $client->save();

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100,
            }});
    ok $res->{error}->{message_to_client} =~ /account is currently disabled/, 'error';

    $client->clr_status('disabled');
    $client->save();
    $pa_client->set_status('cashier_locked', 'test.t', 'just for test');
    $pa_client->save();
    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100,
            }});
    ok $res->{error}->{message_to_client} =~ /Your cashier section is locked/, 'Your cashier section is locked';

    $pa_client->clr_status('cashier_locked');
    $pa_client->save();
    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 1500,
            }});
    ok $res->{error}->{message_to_client} =~ /you cannot withdraw./, 'you cannot withdraw.';

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100,
                dry_run               => 1,
            }});
    is $res->{status}, 2, 'paymentagent_transfer dry_run ok';

    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100,
            }});
    ok $res->{error}->{message_to_client} =~ /An error occurred while processing request/, 'An error occurred while processing request';

    # need unfreeze_client after transfer error
    BOM::Platform::Transaction->unfreeze_client($client->loginid);
    BOM::Platform::Transaction->unfreeze_client($pa_client->loginid);
    $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
            token => 'blabla',
            args  => {
                paymentagent_transfer => 1,
                transfer_to           => $client->loginid,
                currency              => 'USD',
                amount                => 100,
            }});
    is $res->{status}, 1, 'paymentagent_transfer ok again';
}

done_testing();
