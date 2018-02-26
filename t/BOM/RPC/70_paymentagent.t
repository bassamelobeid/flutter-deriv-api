use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Data::Dumper;
use Postgres::FeedDB::CurrencyConverter qw(in_USD amount_from_to_currency);

use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Model::AccessToken;
use BOM::Database::ClientDB;

my $client_mocked = Test::MockModule->new('BOM::User::Client');
$client_mocked->mock('add_note', sub { return 1 });

my $mocked_CurrencyConverter = Test::MockModule->new('Postgres::FeedDB::CurrencyConverter');
$mocked_CurrencyConverter->mock(
    'in_USD',
    sub {
        my $price         = shift;
        my $from_currency = shift;

        $from_currency eq 'BTC' and return 5000 * $price;
        $from_currency eq 'USD' and return 1 * $price;

        return 0;
    });

my ($client, $pa_client, $crypto_client, $crypto_pa_client);
{
    $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client->set_default_account('USD');

    $crypto_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $crypto_client->set_default_account('BTC');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 500,
        remark   => 'free gift',
    );

    $crypto_client->payment_free_gift(
        currency => 'BTC',
        amount   => 1,
        remark   => 'free gift',
    );

    $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $pa_client->set_default_account('USD');

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
        target_country        => 'id',
    });
    $pa_client->save;

    $crypto_pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $crypto_pa_client->set_default_account('BTC');

    # make him a payment agent, this will turn the transfer into a paymentagent transfer.
    $crypto_pa_client->payment_agent({
        payment_agent_name    => 'Joe',
        url                   => 'http://www.sample.com/',
        email                 => 'joe@sample.com',
        phone                 => '+12345678',
        information           => 'Test Information',
        summary               => 'Test Summary',
        commission_deposit    => 0,
        commission_withdrawal => 0,
        is_authenticated      => 't',
        currency_code         => 'BTC',
        target_country        => 'id',
    });
    $crypto_pa_client->save;
}

my $m = BOM::Database::Model::AccessToken->new;
my ($client_token, $pa_client_token, $crypto_client_token, $crypto_pa_client_token) = (
    $m->create_token($client->loginid,           'pa test'),
    $m->create_token($pa_client->loginid,        'pa test'),
    $m->create_token($crypto_client->loginid,    'pa test'),
    $m->create_token($crypto_pa_client->loginid, 'pa test'));

my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');
$mock_utility->mock('is_verification_token_valid', sub { return {status => 1} });

## paymentagent_withdraw
my ($res, $client_db, $pa_client_db, $client_b_balance, $pa_client_b_balance);
subtest 'paymentagent_withdraw' => sub {
    my $code = 'mocked';
    subtest 'payment agent USD' => sub {
        $client              = BOM::User::Client->new({loginid => $client->loginid});
        $client_b_balance    = $client->default_account->balance;
        $pa_client_b_balance = $pa_client->default_account->balance;

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{status},            1,     'paymentagent_withdraw ok';
        is $res->{paymentagent_name}, 'Joe', 'Got correct payment agent name';

        ## after withdraw, check both balance
        $client = BOM::User::Client->new({loginid => $client->loginid});
        ok $client->default_account->balance == $client_b_balance - 100, '- 100';
        $pa_client = BOM::User::Client->new({loginid => $pa_client->loginid});
        ok $pa_client->default_account->balance == $pa_client_b_balance + 100, '+ 100';

        ## test for failure
        foreach my $amount (-1, 1, 2001) {
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                    client => $client,
                    args   => {
                        paymentagent_withdraw => 1,
                        paymentagent_loginid  => $pa_client->loginid,
                        currency              => 'USD',
                        verification_code     => $code,
                        (defined $amount) ? (amount => $amount) : (),
                    }});
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        }

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => 'VRTC000001',
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{error}->{message_to_client}, 'The payment agent account does not exist.', 'the Payment Agent does not exist';

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'RMB',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{error}->{message_to_client},
            'You cannot perform this action, as RMB is not default currency for your account ' . $client->loginid . '.',
            'your currency of RMB is unavailable';

        $client->set_status('withdrawal_locked', 'test.t', "just for test");
        $client->save();
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{error}->{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.', 'error';

        $client->clr_status('withdrawal_locked');
        $client->save();
        $pa_client->set_status('cashier_locked', 'test.t', 'just for test');
        $pa_client->save();
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{error}->{message_to_client},
            'You cannot perform the withdrawal to account ' . $pa_client->loginid . ", as the payment agent's cashier is locked.",
            'This Payment Agent cashier section is locked';

        $pa_client->clr_status('cashier_locked');
        $pa_client->save();
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 500,
                    verification_code     => $code
                }});
        ok $res->{error}->{message_to_client} =~ /Sorry, you cannot withdraw. Your account balance is/, 'you cannot withdraw.';

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    dry_run               => 1,
                    verification_code     => $code
                }});
        is $res->{status}, 2, 'paymentagent_withdraw dry_run ok';

        $client_db = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        });

        $pa_client_db = BOM::Database::ClientDB->new({
            client_loginid => $pa_client->loginid,
        });

        # freeze so that it throws error
        $client_db->freeze;

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{error}->{message_to_client}, 'Sorry, an error occurred whilst processing your request. Please try again in one minute.',
            'An error occurred while processing request';

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        ok $res->{error}->{message_to_client} =~ /Request too frequent. Please try again later./, 'Too many attempts';

        # sleep for 3 seconds as we have limit for 2 seconds
        sleep 3;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    verification_code     => $code
                }});
        is $res->{status}, 1, 'paymentagent_withdraw ok again';
    };

    subtest 'paymentagent BTC' => sub {
        $crypto_client       = BOM::User::Client->new({loginid => $crypto_client->loginid});
        $client_b_balance    = $crypto_client->default_account->balance;
        $pa_client_b_balance = $crypto_pa_client->default_account->balance;

        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $crypto_client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $crypto_pa_client->loginid,
                    currency              => 'USD',
                    verification_code     => $code,
                    amount                => 1,
                }});
        ok $res->{error}->{message_to_client} =~ /You cannot perform this action, as USD is not default currency for your account/,
            "Invalid currency";

        foreach my $amount (-1, 0.001, 6) {
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                    client => $crypto_client,
                    args   => {
                        paymentagent_withdraw => 1,
                        paymentagent_loginid  => $crypto_pa_client->loginid,
                        currency              => 'BTC',
                        verification_code     => $code,
                        (defined $amount) ? (amount => $amount) : (),
                    }});
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        }

        sleep 3;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw({
                client => $crypto_client,
                args   => {
                    paymentagent_withdraw => 1,
                    paymentagent_loginid  => $crypto_pa_client->loginid,
                    currency              => 'BTC',
                    amount                => 0.004,
                    verification_code     => $code
                }});
        diag explain $res unless $res->{status};
        is $res->{status}, 1, 'paymentagent_withdraw ok again';

        $crypto_client = BOM::User::Client->new({loginid => $crypto_client->loginid});
        ok $crypto_client->default_account->balance == $client_b_balance - 0.004, '- 0.004';
        $crypto_pa_client = BOM::User::Client->new({loginid => $crypto_pa_client->loginid});
        ok $crypto_pa_client->default_account->balance == $pa_client_b_balance + 0.004, '+ 0.004';
    };
};

## transfer
subtest 'paymentagent_transfer' => sub {
    subtest 'paymentagent USD' => sub {
        $pa_client = BOM::User::Client->new({loginid => $pa_client->loginid});
        $client    = BOM::User::Client->new({loginid => $client->loginid});
        $client_b_balance    = $client->default_account->balance;
        $pa_client_b_balance = $pa_client->default_account->balance;

        # from client to pa_client is not allowed
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100
                }});
        is $res->{error}->{message_to_client}, 'You are not authorized for transfers via payment agents.', 'You are not a Payment Agent';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100
                }});
        is $res->{status}, 1, 'paymentagent_transfer ok';
        is $res->{client_to_full_name}, $client->full_name, 'Got correct payment agent name';
        is $res->{client_to_loginid},   $client->loginid,   'Got correct client to loginid';

        ## after withdraw, check both balance
        $client = BOM::User::Client->new({loginid => $client->loginid});
        ok $client->default_account->balance == $client_b_balance + 100, '+ 100';
        $pa_client = BOM::User::Client->new({loginid => $pa_client->loginid});
        ok $pa_client->default_account->balance == $pa_client_b_balance - 100, '- 100';

        ## test for failure
        foreach my $amount (-1, 1, 2001) {
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                    client => $pa_client,
                    args   => {
                        paymentagent_transfer => 1,
                        transfer_to           => $client->loginid,
                        currency              => 'USD',
                        (defined $amount) ? (amount => $amount) : (),
                    }});
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        }

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => 'VRTC000001',
                    currency              => 'USD',
                    amount                => 100
                }});
        ok $res->{error}->{message_to_client} =~ /Login ID \(VRTC000001\) does not exist/, 'Login ID (VRTC000001) does not exist';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => 'OK992002',
                    currency              => 'USD',
                    amount                => 100,
                    dry_run               => 1
                }});
        ok $res->{error}->{message_to_client} =~ /Login ID \(OK992002\) does not exist/, 'Login ID (VRTC000001) does not exist';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'EUR',
                    amount                => 100
                }});
        is $res->{error}->{message_to_client},
            'You cannot perform this action, as EUR is not the default account currency for payment agent ' . $pa_client->loginid . '.',
            'payment not allowed across different currencies';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $pa_client->loginid,
                    currency              => 'USD',
                    amount                => 100
                }});
        is $res->{error}->{message_to_client}, 'Payment agent transfers are not allowed within the same account.', 'self, it is not allowed';

        $client->set_status('disabled', 'test.t', "just for test");
        $client->save();

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
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
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                }});
        is $res->{error}->{message_to_client}, 'You cannot perform this action, as your account is cashier locked.', 'Your cashier section is locked';

        $pa_client->clr_status('cashier_locked');
        $pa_client->save();
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 1500,
                }});
        ok $res->{error}->{message_to_client} =~ /you cannot withdraw./, 'you cannot withdraw.';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                    dry_run               => 1,
                }});
        is $res->{status}, 2, 'paymentagent_transfer dry_run ok';

        $client_db = BOM::Database::ClientDB->new({
            client_loginid => $client->loginid,
        });

        $pa_client_db = BOM::Database::ClientDB->new({
            client_loginid => $pa_client->loginid,
        });

        # freeze so that it throws error
        $client_db->freeze;

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                }});
        is $res->{error}->{message_to_client}, 'Sorry, an error occurred whilst processing your request. Please try again in one minute.',
            'An error occurred while processing request';

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                }});
        ok $res->{error}->{message_to_client} =~ /Request too frequent. Please try again later./, 'Too many attempts';

        # sleep for 3 seconds as we have limit for 2 seconds
        sleep 3;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                }});
        is $res->{status}, 1, 'paymentagent_transfer ok again';

        sleep 3;
        # test max, min withdraw
        $pa_client->payment_agent->max_withdrawal(50);
        $pa_client->payment_agent->min_withdrawal(20);
        $pa_client->save();
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 100,
                }});
        ok $res->{error}->{message_to_client} =~ /Invalid amount. Maximum withdrawal allowed is 50./, 'Amount greater than max withdrawal';

        sleep 3;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $client->loginid,
                    currency              => 'USD',
                    amount                => 10,
                }});
        ok $res->{error}->{message_to_client} =~ /Invalid amount. Minimum withdrawal allowed is 20./, 'Amount less than min withdrawal';
    };

    subtest 'paymentagent BTC' => sub {
        $crypto_pa_client = BOM::User::Client->new({loginid => $crypto_pa_client->loginid});
        $crypto_client    = BOM::User::Client->new({loginid => $crypto_client->loginid});
        $client_b_balance = $crypto_client->default_account->balance;
        $pa_client_b_balance = $crypto_pa_client->default_account->balance;

        ## test for failure
        foreach my $amount (-1, 0.001, 6) {
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                    client => $crypto_pa_client,
                    args   => {
                        paymentagent_transfer => 1,
                        transfer_to           => $crypto_client->loginid,
                        currency              => 'BTC',
                        (defined $amount) ? (amount => $amount) : (),
                    }});
            ok $res->{error}->{message_to_client} =~ /Invalid amount/, "test amount $amount";
        }

        sleep 3;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer({
                client => $crypto_pa_client,
                args   => {
                    paymentagent_transfer => 1,
                    transfer_to           => $crypto_client->loginid,
                    currency              => 'BTC',
                    amount                => 0.002
                }});
        diag explain $res unless $res->{status};
        is $res->{status}, 1, 'paymentagent_transfer ok';
        is $res->{client_to_full_name}, $crypto_client->full_name, 'Got correct payment agent name';
        is $res->{client_to_loginid},   $crypto_client->loginid,   'Got correct client to loginid';

        ## after withdraw, check both balance
        $crypto_client = BOM::User::Client->new({loginid => $crypto_client->loginid});
        ok $crypto_client->default_account->balance == $client_b_balance + 0.002, '+ 0.002';
        $crypto_pa_client = BOM::User::Client->new({loginid => $crypto_pa_client->loginid});
        ok $crypto_pa_client->default_account->balance == $pa_client_b_balance - 0.002, '- 0.002';
    };
};

done_testing();
