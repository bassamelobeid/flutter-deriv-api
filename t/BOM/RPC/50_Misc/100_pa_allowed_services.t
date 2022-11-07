use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::Deep;
use Test::Warnings qw(warning);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Email                           qw(:no_event);
use BOM::RPC::v3::Utility;
use BOM::Platform::Token::API;
use BOM::Database::Model::AccessToken;
use BOM::User;
use BOM::Test::Helper::Client;
use BOM::Test::RPC::QueueClient;
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
populate_exchange_rates({BTC => 5000});

my $mock_currency_converter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mock_currency_converter->redefine(offer_to_clients => 1);

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';

my $agent_name         = 'Joe';
my $payment_agent_args = {
    payment_agent_name    => $agent_name,
    currency_code         => 'USD',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized'
};

my $email_pa  = 'pa_restrictions_pa@binary.com';
my $client_pa = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_pa
});
$client_pa->account('USD');
BOM::Test::Helper::Client::top_up($client_pa, 'USD', 1000);
my $user_pa = BOM::User->create(
    email    => $email_pa,
    password => 'abcd'
);
$user_pa->add_client($client_pa);
$client_pa->payment_agent($payment_agent_args);
$client_pa->save;
$client_pa->get_payment_agent->set_countries([$client_pa->residence]);

my $email_cr  = 'pa_restrictions_cr@binary.com';
my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_cr
});
$client_cr->account('USD');
BOM::Test::Helper::Client::top_up($client_cr, 'USD', 1000);
my $user_cr = BOM::User->create(
    email    => $email_cr,
    password => 'abcd'
);
$user_cr->add_client($client_cr);

my $client_pa2 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => $email_cr
});
$client_pa2->account('USD');
BOM::Test::Helper::Client::top_up($client_pa2, 'USD', 1000);
$user_cr->add_client($client_pa);
$agent_name = 'Bob';
$client_pa2->payment_agent($payment_agent_args);
$client_pa2->save;
$client_pa2->get_payment_agent->set_countries([$client_pa->residence]);

my $token_pa  = BOM::Platform::Token::API->new->create_token($client_pa->loginid,  'test token');
my $token_cr  = BOM::Platform::Token::API->new->create_token($client_cr->loginid,  'test token');
my $token_pa2 = BOM::Platform::Token::API->new->create_token($client_pa2->loginid, 'test token');

my $c = BOM::Test::RPC::QueueClient->new();

my $mock_pa      = Test::MockModule->new('BOM::User::Client::PaymentAgent');
my $tier_details = {};
$mock_pa->redefine(tier_details => sub { $tier_details });

subtest 'cashier_withdraw restriction' => sub {
    subtest 'Verify email - cashier withdrawal' => sub {
        my @emitted;
        no warnings 'redefine';
        local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };
        my $method = 'verify_email';

        my $params = {
            language      => 'EN',
            token         => $token_pa,
            token_details => {loginid => $client_pa->loginid},
            args          => {
                $method => $client_pa->email,
                type    => 'payment_withdraw'
            },
        };

        $tier_details = {};

        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'Cashier withdrawal is not available for PAs by default')
            ->error_message_is('This service is not available for payment agents.', 'Serivce unavailability error message');

        is(scalar @emitted, 0, 'no email as token email different from passed email');

        $tier_details->{cashier_withdraw} = 1;

        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error when the service is made available.');

        is($emitted[0], 'request_payment_withdraw', 'type=request_payment_withdraw');
        ok($emitted[1]->{properties}, 'Properties are set');
        is($emitted[1]->{properties}{email}, lc $params->{args}->{verify_email}, 'email is set');
        is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
        undef @emitted;
    };

    subtest 'cashier forward' => sub {
        my $method = 'cashier';

        my $params = {
            language => 'EN',
            token    => $token_pa,
            args     => {
                $method => 'withdraw',
            },
        };

        $params->{args}->{verification_code} = BOM::Platform::Token->new({
                email       => $client_pa->email,
                expires_in  => 3600,
                created_for => 'payment_withdraw',
            })->token;

        # Let's set a default error for normal clients (it is too hard to make a successful cashier forward in a test script).
        $client_pa->status->set('withdrawal_locked', 'system', 'locked for security reason');

        $tier_details = {};

        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'PA withdrawal is not available for PAs by default')
            ->error_message_is('This service is not available for payment agents.', 'Serivce unavailability error message');

        $tier_details->{cashier_withdraw} = 1;

        $params->{args}->{verification_code} = BOM::Platform::Token->new({
                email       => $client_pa->email,
                expires_in  => 3600,
                created_for => 'payment_withdraw',
            })->token;

        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_message_is('Your account is locked for withdrawals.', 'Expected error, like a normal client.');

        $client_pa->status->clear_withdrawal_locked;
    };

    subtest 'get account status' => sub {
        my $method = 'get_account_status';
        my $params = {
            language => 'EN',
            token    => $token_pa,
            args     => {
                $method => 1,
            },
        };

        $tier_details = {};

        my $res = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
        cmp_deeply $res->{status},             superbagof('withdrawal_locked'),               'Cashier is locked';
        cmp_deeply $res->{cashier_validation}, superbagof('WithdrawServiceUnavailableForPA'), 'Expected cashier verifications flags for the FE.';

        $tier_details->{cashier_withdraw} = 1;

        $res = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
        cmp_deeply $res->{status},             none('withdrawal_locked'),               'Withdrawal is unlocked after allowing the service';
        cmp_deeply $res->{cashier_validation}, none('WithdrawServiceUnavailableForPA'), 'Validation flag is removed.';

        $mock_pa->redefine(status => undef);
        is_deeply warning { $c->call_ok($method, $params)->has_no_system_error->has_no_error->result }, [],
            'No warning when the PA status is undefined';
        $mock_pa->unmock('status');

        $tier_details = {};
    };
};

subtest 'transfer to a non-pa sibling API call' => sub {
    my $method = 'transfer_between_accounts';

    my $sibling_btc = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email_pa
    });
    $sibling_btc->account('BTC');
    BOM::Test::Helper::Client::top_up($sibling_btc, 'BTC', 1);
    $user_pa->add_client($sibling_btc);
    my $pa = $client_pa->get_payment_agent;

    my $params = {
        language => 'EN',
        token    => BOM::Platform::Token::API->new->create_token($sibling_btc->loginid, 'test token'),
        args     => {
            $method      => 1,
            amount       => 0.011,
            currency     => "BTC",
            account_from => $sibling_btc->loginid,
            account_to   => $client_pa->loginid,
        },
    };

    $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error transfering from a non-pa to a pa sibling.');

    $params->{token} = $token_pa;
    $params->{args}  = {
        $method      => 1,
        amount       => 100,
        currency     => "USD",
        account_from => $client_pa->loginid,
        account_to   => $sibling_btc->loginid,
    };

    $c->call_ok($method, $params)
        ->has_no_system_error->has_error->error_code_is('TransferToNonPaSibling',
        'Transferring from a payment agent to non-pa sibling is not allowed.')
        ->error_message_is('You are not allowed to transfer to this account.', 'Correct error message.');

    $tier_details = {
        cashier_withdraw => 1,
        p2p              => 1,
        trading          => 1,
        transfer_to_pa   => 1
    };

    $c->call_ok($method, $params)->has_no_system_error->has_error->error_code_is('TransferToNonPaSibling')
        ->error_message_is('You are not allowed to transfer to this account.',
        'Transfer to a non-pa sibling is strictly blocked, even if we allow all services.');

    $tier_details = {};
    $sibling_btc->payment_agent({%$payment_agent_args, max_withdrawal => 0.00001});
    $sibling_btc->save;
    $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error transfering from a pa to a pa sibling.');
};

subtest 'transfer_to_pa restriction' => sub {
    subtest 'Verify email - payment agent withdrawal' => sub {
        my @emitted;
        no warnings 'redefine';
        local *BOM::Platform::Event::Emitter::emit = sub { @emitted = @_ };

        my $method = 'verify_email';
        my $params = {
            language      => 'EN',
            token         => $token_pa,
            token_details => {loginid => $client_pa->loginid},
            args          => {
                $method => $client_pa->email,
                type    => 'paymentagent_withdraw',
            },
        };

        $tier_details = {};

        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('CashierForwardError', 'PA withdrawal is not available for PAs by default')
            ->error_message_is('You are not allowed to transfer to other payment agents.', 'Serivce unavailability error message');

        is(scalar @emitted, 0, 'no email as token email different from passed email');

        $tier_details->{transfer_to_pa} = 1;
        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error when the service is made available.');

        is($emitted[0], 'request_payment_withdraw', 'type=request_payment_withdraw');
        ok($emitted[1]->{properties}, 'Properties are set');
        is($emitted[1]->{properties}{email}, lc $params->{args}->{verify_email}, 'email is set');
        is $emitted[1]->{properties}{live_chat_url}, 'https://www.binary.com/en/contact.html?is_livechat_open=true', 'live_chat_url is set';
        undef @emitted;

        $tier_details = {};
    };

    subtest 'paymentagent_withdrawal API call' => sub {
        my $method = 'paymentagent_withdraw';
        my $params = {
            language => 'EN',
            token    => $token_cr,
            args     => {
                $method              => 1,
                amount               => 10,
                currency             => "USD",
                paymentagent_loginid => $client_pa->loginid,
                dry_run              => 1,
            },
        };
        $params->{args}->{verification_code} = BOM::Platform::Token->new({
                email       => $client_cr->email,
                expires_in  => 3600,
                created_for => $method,
            })->token;

        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error transfering from a client to PA');

        $params->{token} = $token_pa2;
        $params->{args}->{verification_code} = BOM::Platform::Token->new({
                email       => $client_pa2->email,
                expires_in  => 3600,
                created_for => $method,
            })->token;

        $tier_details = {};

        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PaymentAgentWithdrawError', 'PA withdrawal is not available for PAs by default')
            ->error_message_is('You are not allowed to transfer to other payment agents.', 'Serivce unavailability error message');

        $tier_details->{transfer_to_pa} = 1;

        $params->{args}->{verification_code} = BOM::Platform::Token->new({
                email       => $client_pa2->email,
                expires_in  => 3600,
                created_for => $method,
            })->token;
        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error when the service is made available.');

        $tier_details = {};
    };

    subtest 'paymentagent_transfer API call' => sub {
        my $method = 'paymentagent_transfer';
        my $params = {
            language => 'EN',
            token    => $token_pa,
            args     => {
                $method     => 1,
                amount      => 10,
                currency    => "USD",
                transfer_to => $client_cr->loginid,
            },
        };

        $tier_details = {};

        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error transfering from a PA to a client');

        $params->{args}->{transfer_to} = $client_pa2->loginid;
        $c->call_ok($method, $params)
            ->has_no_system_error->has_error->error_code_is('PaymentAgentTransferError', 'Transfer to another PA is not available for PAs by default')
            ->error_message_is('You are not allowed to transfer to other payment agents.', 'Serivce unavailability error message');

        $tier_details->{transfer_to_pa} = 1;

        $c->call_ok($method, $params)->has_no_system_error->has_no_error('No error when the service is made available.');

        $tier_details = {};
    };
};

subtest 'get account status' => sub {
    my $method = 'get_account_status';

    my $params = {
        language => 'EN',
        token    => $token_pa,
        args     => {
            $method => 1,
        },
    };

    my $mock_pa = Test::MockModule->new('BOM::User::Client::PaymentAgent');

    my @test_cases = ({
            status       => 'applied',
            tier_details => {},
            p2p_blocked  => 0,
            title        => 'status => applied, no service allowed'
        },
        {
            status       => 'applied',
            tier_details => => {p2p => 1},
            p2p_blocked  => 0,
            title        => 'status = applied, p2p allowed'
        },
        {
            status       => 'authorized',
            tier_details => {},
            p2p_blocked  => 1,
            title        => 'status = authorized, no service allowed'
        },
        {
            status       => 'authorized',
            tier_details => => {p2p => 1},
            p2p_blocked  => 0,
            title        => 'status = authorized, p2p service allowed'
        },
    );

    for my $test_case (@test_cases) {
        $mock_pa->redefine(status       => $test_case->{status});
        $mock_pa->redefine(tier_details => $test_case->{tier_details});

        my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;

        if ($test_case->{p2p_blocked}) {
            cmp_deeply $result->{status}, superbagof('p2p_blocked_for_pa'), "P2P-blocked status is found: $test_case->{title}";
        } else {
            cmp_deeply $result->{status}, noneof('p2p_blocked_for_pa'), "P2P-blocked status is not found: $test_case->{title}";
        }
    }

};

done_testing;

