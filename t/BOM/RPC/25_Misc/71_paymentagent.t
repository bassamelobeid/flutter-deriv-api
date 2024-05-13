#!/usr/bin/perl

## Test of 'paymentagent_transfer' and 'paymentagent_withdraw'

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Clone      qw( clone );
use List::Util qw( first shuffle );
use YAML::XS;
use Data::Dumper;

use Business::Config::LandingCompany;

use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );
use BOM::Test::Helper::Client                  qw( top_up );
use ExchangeRates::CurrencyConverter           qw( convert_currency );
use Format::Util::Numbers                      qw( formatnumber );
use BOM::Config::Runtime;

my ($Alice, $Alice_id, $Bob, $Bob_id, $test, $test_currency, $test_amount, $amount_boost, $dry_run, $testargs, $res);

my @crypto_currencies = qw/ BTC ETH LTC /;       ## ETC not enabled for CR landing company
my @fiat_currencies   = qw/ AUD EUR GBP USD /;

## Things hard-coded into Cashier.pm:
my $MAX_DESCRIPTION_LENGTH = 250;

my $payment_config   = BOM::Config::payment_agent;
my $withdrawal_limit = $payment_config->{transaction_limits}->{withdraw};
my $transfer_limit   = $payment_config->{transaction_limits}->{transfer};

my $MAX_DAILY_WITHDRAW_AMOUNT_WEEKDAY = $withdrawal_limit->{weekday}->{amount_in_usd_per_day};
my $MAX_DAILY_WITHDRAW_AMOUNT_WEEKEND = $withdrawal_limit->{weekend}->{amount_in_usd_per_day};
my $MAX_DAILY_WITHDRAW_TXNS_WEEKDAY   = $withdrawal_limit->{weekday}->{transactions_per_day};
my $MAX_DAILY_WITHDRAW_TXNS_WEEKEND   = $withdrawal_limit->{weekend}->{transactions_per_day};
my $MAX_DAILY_TRANSFER_TXNS           = $transfer_limit->{transactions_per_day};
my $MAX_DAILY_TRANSFER_AMOUNT_USD     = $transfer_limit->{amount_in_usd_per_day};

## Clients will need a payment agent.
## Keep the name separate as paymentagent_withdraw returns it
my $agent_name         = 'Joe';
my $payment_agent_args = {
    payment_agent_name    => $agent_name,
    currency_code         => 'USD',
    email                 => 'joe@example.com',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    status                => 'authorized',
};

## For client authentication document tests.
## The expiration_date is left out on purpose and should be explicitly set each time.
my $auth_document_args = {
    document_type              => 'passport',
    document_format            => 'TST',
    document_path              => '/tmp/testfile2.tst',
    authentication_method_code => 'TESTY_TESTY',
    status                     => 'verified',
    checksum                   => 'Abcder12345678',
    file_name                  => 'some_test.txt',
};

## Used for test safety, and to mock some subs:
my $mock_cashier = Test::MockModule->new('BOM::RPC::v3::Cashier');

## Used to mock today_payment_agent_withdrawal_sum_count
my $mock_pa = Test::MockModule->new('BOM::User::Client::PaymentAgent');

## Used to mock default_account, payment_account_transfer, landing_company, currency:
my $mock_user_client = Test::MockModule->new('BOM::User::Client');

## (Don't ever send an email out when a client is created)
$mock_user_client->mock('add_note', sub { return 1 });
## We do not want to worry about this right now:
$mock_user_client->mock('is_tnc_approval_required', sub { return 0; });

my $mock_account = Test::MockModule->new('BOM::User::Client::Account');

## Used to simulate a payment agent not existing:
my $mock_client_paymentagent = Test::MockModule->new('BOM::User::Client::PaymentAgent');

my $mock_client = Test::MockModule->new('BOM::User::Client');

## This is needed else we error out from trying to reach Redis for conversion information:
my $mock_currencyconverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mock_currencyconverter->mock(
    'in_usd',
    sub {
        return (grep { $_[1] eq $_ } @crypto_currencies) ? 5000 * $_[0] : $_[0];
    });
## Cashier now imports it, so we need to mock it here too:
$mock_cashier->mock(
    'in_usd',
    sub {
        return (grep { $_[1] eq $_ } @crypto_currencies) ? 5000 * $_[0] : $_[0];
    });

## Used to force weekend/weekday, as there is date-dependent logic in Cashier.pm:
my $mock_date_utility = Test::MockModule->new('Date::Utility');

## Used to force non-svg landing companies to allow payment agents:
my $mock_landingcompany = Test::MockModule->new('LandingCompany');

## Used to make sure verification tokens always pass:
my $mock_utility = Test::MockModule->new('BOM::RPC::v3::Utility');

## Used to make sure that there is always an authenticated agent in client's country
my $mock_payment_agent = Test::MockModule->new('BOM::Database::DataMapper::PaymentAgent');

## Used to set global statuses:
my $runtime_system = BOM::Config::Runtime->instance->app_config->system;

## Used to check for special cases on the payment agent exclusion list
my $payment_agent_exclusion_list = BOM::Config::Runtime->instance->app_config->payments->payment_agent_residence_check_exclusion;

## Cannot test if we do not know some edge cases:
my $payment_withdrawal_limits = Business::Config::LandingCompany->new()->payment_limit->{withdrawal_limits};
my $payment_transfer_limits   = BOM::Config::payment_agent()->{transaction_limits}->{transfer};

my $mock_documents = Test::MockModule->new('BOM::User::Client::AuthenticationDocuments');

my $emitted_events = {};
my $mock_events    = Test::MockModule->new('BOM::Platform::Event::Emitter');
$mock_events->mock('emit' => sub { push $emitted_events->{$_[0]}->@*, $_[1] });

# Mocking all of the necessary exchange rates in redis.
my $redis_exchangerates = BOM::Config::Redis::redis_exchangerates_write();
my @all_currencies      = qw(EUR ETH AUD eUSDT tUSDT BTC LTC UST USDC USD GBP);

for my $currency (@all_currencies) {
    $redis_exchangerates->hmset(
        'exchange_rates::' . $currency . '_USD',
        quote => 1,
        epoch => time
    );
}

##
## Test of 'rpc paymentagent_transfer' in Cashier.pm
##

## Transfer money from one person to another: Alice (client) to Bob (transfer_to)

## https://github.com/regentmarkets/binary-websocket-api/blob/master/config/v3/paymentagent_transfer/send.json
## paymentagent_transfer arguments:
## 'client': [BOM::User::Client object] who the money comes FROM; we call them Alice
## 'website_name': [string] only used in outgoing confirmation email
## 'args' : [hashref] everything else below
##   'paymentagent_transfer': [integer] must be "1"
##   'transfer_to': [string] (loginid) who the money goes TO; we call them Bob
##   'currency': [string]
##   'amount': [number]
##   'dry_run': [integer] (0 or 1). "If 1, just do validation"

sub reset_transfer_testargs {
    $testargs = {
        client => $Alice,
        args   => {
            paymentagent_transfer => 1,
            transfer_to           => $Bob_id,
            currency              => $test_currency,
            amount                => $test_amount,
            dry_run               => $dry_run,
        }};
    return;
}

sub authenticate_client {
    my ($clientdbh, $loginid) = @_;

    my $SQL = 'INSERT INTO betonmarkets.client_authentication_method
            (client_loginid, authentication_method_code, status, description)
            VALUES (?,?,?,?)';
    my $sth_add_method = $clientdbh->prepare($SQL);

    $sth_add_method->execute($loginid, 'ID_DOCUMENT', 'pass', 'Testing only');
}

sub deauthenticate_client {
    my ($clientdbh, $loginid) = @_;

    my $SQL               = 'DELETE FROM betonmarkets.client_authentication_method WHERE client_loginid = ?';
    my $sth_delete_method = $clientdbh->prepare($SQL);
    $sth_delete_method->execute($loginid);
}

## This helps prevent cut-n-paste errors in this file:
$mock_cashier->mock(
    'paymentagent_withdraw',
    sub {
        my $line = (caller)[2];
        die "Wrong paymentagent function called at line $line: this is the transfer section!\n";
    });

my $loop = 0;
for my $transfer_currency (@fiat_currencies, @crypto_currencies) {

    $loop++;
    $test_currency = $transfer_currency;

    $test_amount  = (grep { $_ eq $test_currency } @crypto_currencies) ? '0.00200000' : '100.40';
    $amount_boost = (grep { $_ eq $test_currency } @crypto_currencies) ? '0.0001'     : 1;
    my $precision = (grep { $_ eq $test_currency } @crypto_currencies) ? 8 : 2;

    my $email    = 'abc1' . rand . '@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::User::Password::hashpw($password);

    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    # Create brand new clients for each loop
    my $broker = 'CR';
    $Alice = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
        first_name  => 'Alice'
    });
    $Alice_id = $Alice->loginid;
    $Alice->set_default_account($test_currency);

    $user->add_client($Alice);

    $email = 'abc2' . rand . '@binary.com';
    $user  = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $Bob = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
        first_name  => 'Bob'
    });
    $Bob_id = $Bob->loginid;
    $Bob->set_default_account($test_currency);

    $user->add_client($Bob);

    my $client_no_currency = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
    });

    diag "Transfer currency is $test_currency. Created Alice as $Alice_id and Bob as $Bob_id";

    $dry_run = 1;
    reset_transfer_testargs();

    subtest "paymentagent_transfer $test_currency" => sub {

        $test = 'Client account starts with a zero balance';
        is($Alice->default_account->balance, 0, $test) or BAIL_OUT $test;

        $test = 'Transfer_to account starts with a zero balance';
        is($Bob->default_account->balance, 0, $test) or BAIL_OUT $test;

        ## In rough order of the code in Cashier.pm

        $test               = 'Transfer fails if client has a virtual broker (VRTC)';
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $res                = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Permission denied.', $test);
        reset_transfer_testargs();

        ##
        ## Tests for _validate_amount in Cashier.pm
        ##

        $test = 'Transfer fails if given an invalid amount';
        for my $bad_amount (qw/ abc 1.2.3 1;2 . /) {
            $testargs->{args}{amount} = $bad_amount;
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            is($res->{error}{message_to_client}, 'Invalid amount.', "$test ($bad_amount)");
        }
        reset_transfer_testargs();

        $test                       = 'Transfer fails if no currency is given';
        $testargs->{args}{currency} = '';
        $res                        = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Invalid currency.', $test);

        $test                       = 'Transfer fails if invalid currency is given';
        $testargs->{args}{currency} = 'Gil';
        $res                        = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Invalid currency.', $test);

        ## Precisions can be viewed via Format::Util::Numbers::get_precision_config();
        ## These checks rely on a local YAML file (e.g. 'precision.yml')
        for my $currency (@crypto_currencies, @fiat_currencies) {
            $testargs->{args}{currency} = $currency;
            my $local_precision = (grep { $_ eq $currency } @crypto_currencies) ? 8 : 2;
            $testargs->{args}{amount} = '1.2' . ('0' x $local_precision) . '1';
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            is(
                $res->{error}{message_to_client},
                "Invalid amount. Amount provided can not have more than $local_precision decimal places.",
                "$test ($currency must be <= $local_precision decimal places)"
            );
        }

        $test = 'Transfer failure gives the expected error code (PaymentAgentTransferError)';
        ## Quick check at least this one time. This code should not change.
        is($res->{error}{code}, 'PaymentAgentTransferError', $test);
        reset_transfer_testargs();

        ##
        ## Global status tests
        ##

        $test = 'Transfer fails if all payments are suspended';
        my $disabled_message = 'Sorry, this facility is temporarily disabled due to system maintenance.';
        $runtime_system->suspend->payments(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, $disabled_message, $test);
        $runtime_system->suspend->payments(0);

        $test = 'Transfer fails if all payment agents are suspended';
        $runtime_system->suspend->payment_agents(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, $disabled_message, $test);
        $runtime_system->suspend->payment_agents(0);

        $test = 'Transfer fails if client has no payment agent';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You are not authorized for transfers via payment agents.', $test);
        $payment_agent_args->{currency_code} = $test_currency;
        #make him payment agent
        $Alice->payment_agent($payment_agent_args);
        $Alice->save;

        $test = "We're unable to process this transfer because the client's resident country is not within your portfolio.";
        $Alice->get_payment_agent->set_countries(['id', 'in']);
        my $old_residence = $Bob->residence;
        $Bob->residence('pk');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client},
            qr/We're unable to process this transfer because the client's resident country is not within your portfolio./, $test);
        $Bob->residence($old_residence);
        $Bob->save;

        $test = 'Transfer fails if client landing company does not allow payment agents';
        ## This check relies on a local YAML file (e.g. 'landing_companies.yml')
        ## Only CR allows payment agents currently, so we mock the result here
        $mock_landingcompany->mock('allows_payment_agents', sub { return 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);

        is($res->{error}{message_to_client}, 'The payment agent facility is not available for this account.', $test);
        $mock_landingcompany->unmock('allows_payment_agents');

        $test = 'Transfer fails is amount is over the landing company maximum';
        #set countries for payment agent
        my $currency_type = LandingCompany::Registry::get_currency_type($test_currency);      ## e.g. "fiat"
        my $lim           = BOM::Config::payment_agent()->{payment_limits}{$currency_type};
        my $max           = formatnumber('amount', $test_currency, $lim->{maximum});
        my $min           = formatnumber('amount', $test_currency, $lim->{minimum});
        $testargs->{args}{amount} = $max * 2;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum is $min, maximum is $max.", "$test ($max for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is over the payment agent maximum';
        ## These two checks rely on a local YAML file (e.g. 'landing_companies.yml')
        my $max_amount = formatnumber('amount', $test_currency, $test_amount / 2);
        $Alice->payment_agent->max_withdrawal($max_amount);
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum is $min, maximum is $max_amount.", $test);
        $Alice->payment_agent->max_withdrawal(undef);
        $Alice->save;

        $test                     = 'Transfer fails is amount is under the landing company minimum';
        $testargs->{args}{amount} = $min * 0.5;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum is $min, maximum is $max.", "$test ($min for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is under the payment agent minimum';
        my $min_amount = formatnumber('amount', $test_currency, $test_amount * 2);
        $Alice->payment_agent->min_withdrawal($min_amount);
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum is $min_amount, maximum is $max.", $test);
        $Alice->payment_agent->min_withdrawal(undef);
        $Alice->save;

        # this test assume address_city is a withdrawal requirement for SVG in landing_companies.yml
        $test = 'Transfer fails if missing required details (address_city + address_line_1)';

        $Alice->address_city('');
        $Alice->address_line_1('');
        $Alice->save;

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is $res->{error}{code}, 'ASK_FIX_DETAILS', 'Correct error code for missing required args';
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        cmp_ok(@{$res->{error}->{details}->{fields}}, '==', 2, 'Correct number of details fetched (2)');
        is_deeply($res->{error}->{details}->{fields}, ['address_city', 'address_line_1'], 'Correct fields matched (2)');

        $Alice->address_line_1('Disney land');
        $Alice->save;

        $test = 'Transfer fails if missing required details (address_city)';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        cmp_ok(@{$res->{error}->{details}->{fields}}, '==', 1, 'Correct number of details fetched (1)');
        is_deeply($res->{error}->{details}->{fields}, ['address_city'], 'Correct fields matched (1)');

        $Alice->address_city('Beverly Hills');
        $Alice->save;

        $test                          = "Transfer fails if description is over $MAX_DESCRIPTION_LENGTH characters";
        $testargs->{args}{description} = 'A' x (1 + $MAX_DESCRIPTION_LENGTH);
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Notes must not exceed $MAX_DESCRIPTION_LENGTH/, $test);

        $test                          = 'Transfer fails if transfer_to client does not exist';
        $testargs->{args}{transfer_to} = q{Invalid O'Hare};
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, q{Login ID (INVALID O'HARE) does not exist.}, $test);
        reset_transfer_testargs();

        $test = 'Transfer fails if payment agent and transfer_to client have different landing companies';
        ## First we force the client to use Malta as their landing company:
        $mock_user_client->mock(
            'landing_company',
            sub {
                return LandingCompany::Registry->by_broker($_[0]->loginid eq $Alice_id ? 'MF' : 'CR');
            });

        ## Then we need to declare that Malta can have payment agents too
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Payment agent transfers are not allowed for the specified accounts.', $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $mock_user_client->unmock('landing_company');

        $test = 'Transfer fails if payment agents are suspended in the target country';
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Payment agent transfers are temporarily unavailable in the client's country of residence.", $test);
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

        $test = 'Transfer returns insufficient balance error even when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like $res->{error}{message_to_client}, qr/account has zero balance/, $test;

        $mock_account->redefine(balance => $testargs->{args}->{amount});
        $test = 'Transfer returns a status of 2 when dry_run is set (with mocked sufficient balance)';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 2, $test) or diag Dumper $res;

        $test = 'Transfer returns correct transfer_to client full name when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{client_to_full_name}, $Bob->full_name, $test) or diag Dumper $res;
        $test = 'Transfer works and returns correct transfer_to client loginid when dry_run is set';
        is($res->{client_to_loginid}, $Bob_id, $test);

        $test          = 'You can transfer to client of different residence';
        $old_residence = $Alice->residence;
        $Alice->residence('in');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 2, $test) or diag Dumper $res;
        $Alice->residence($old_residence);
        $Alice->save;
        reset_transfer_testargs();

        $mock_account->unmock_all;

        $test = 'After transfer with dry_run, client account has an unchanged balance';
        is($Alice->default_account->balance, 0, $test);

        $test = 'After transfer with dry_run, transfer_to client account has an unchanged balance';
        is($Bob->default_account->balance, 0, $test);

        $test = 'Transfer fails if argument not passed to payment_account_transfer';
        for my $arg (qw/ toClient currency amount Alice Bob /) {
            ## Cashier.pm invokes BOM::User::Client::Payments->payment_account_transfer
            ## We need some tricky mocking to test the initial checks inside there
            if ($arg =~ /^[A-Z]/) {
                $mock_user_client->mock(
                    'default_account',
                    sub {
                        my $user = shift;
                        return undef if $user->first_name eq $arg;
                        return $mock_user_client->original('default_account')->($user);
                    });
            }
            $mock_user_client->mock(
                'payment_account_transfer',
                sub {
                    my ($fmClient, %args) = @_;
                    $args{$arg} = '';
                    return $mock_user_client->original('payment_account_transfer')->($fmClient, map { $_, $args{$_} } keys %args);
                });
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            $mock_user_client->unmock('payment_account_transfer');
            if ($arg =~ /^[A-Z]/) {
                $mock_user_client->unmock('default_account');
            }
        }

        $test                          = 'Transfer fails if we try to transfer from and to the same account';
        $testargs->{args}{transfer_to} = $Alice_id;
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Payment agent transfers are not allowed within the same account.', $test);

        $dry_run = 0;
        reset_transfer_testargs();
        $test = 'Transfer fails if amount exceeds client balance';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/account has zero balance/, $test);

        ##
        ## At this point in Cashier.pm, we call payment_account_transfer, so we need some funds
        ##

        $test = 'Client account has correct balance after top up';
        ## We need enough to cover all the following tests, which start with $test_amount,
        ## and increaase by $amount_boost after each successful transfer. Thus the '15'
        my $Alice_balance = sprintf('%0.*f', $precision, $test_amount * 15);
        top_up(
            $Alice,
            $test_currency => $Alice_balance,
            'free_gift'
        );
        ## This is used to keep a running tab of amount transferred:
        my $Alice_transferred = 0;
        is($Alice->default_account->balance, $Alice_balance, "$test ($Alice_balance $test_currency)");

        $test = "Transfer fails if over maximum amount per day (USD $MAX_DAILY_TRANSFER_AMOUNT_USD)";
        ## From this point on, we cannot have dry run enabled

        ## Technically, the mock should return that limit in the test_currency, but this large value covers it
        $mock_client->redefine('today_payment_agent_withdrawal_sum_count', sub { return $MAX_DAILY_TRANSFER_AMOUNT_USD * 99, 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client},
            qr/Payment agent transfers are not allowed, as you have exceeded the maximum allowable transfer amount .* for today./, $test);

        $test = "Transfer fails is over the maximum transactions per day (USD $MAX_DAILY_TRANSFER_AMOUNT_USD)";
        $mock_client->redefine('today_payment_agent_withdrawal_sum_count', sub { return 0, $MAX_DAILY_TRANSFER_TXNS * 55; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            'Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.', $test);
        $mock_client->unmock_all;

        $test = 'Transfer fails if agent status = cashier_locked';
        $Alice->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Your account cashier is locked. Please contact us for more information.', $test);
        $Alice->status->clear_cashier_locked;
        $Alice->save;

        $test = 'Transfer fails if client status = disabled';
        $Alice->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account ' . $Alice->loginid . ' is currently disabled.', $test);
        $Alice->status->clear_disabled;
        $Alice->save;

        $test = 'Transfer fails if client status = withdrawal_locked';
        $Alice->status->set('withdrawal_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.', $test);
        $Alice->status->clear_withdrawal_locked;
        $Alice->save;

        $test = 'Transfer fails if transfer_to client status = cashier_locked';
        $Bob->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their cashier is locked.", $test);
        $Bob->status->clear_cashier_locked;
        $Bob->save;

        $test = 'Transfer fails if transfer_to client status = disabled';
        $Bob->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their account is disabled.", $test);
        $Bob->status->clear_disabled;
        $Bob->save;

        $test = 'Transfer fails if transfer_to client status = unwelcome';
        $Bob->status->set('unwelcome', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id", $test);
        $Bob->status->clear_unwelcome;
        $Bob->save;

        $test = 'Transfer fails if transfer_to client is self-excluded';
        $Bob->set_exclusion->exclude_until(Date::Utility->new->plus_time_interval('1d')->date);
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id", $test);
        $Bob->set_exclusion->exclude_until(undef);
        $Bob->save;

        $test                          = 'Transfer fails if transfer_to client has not set currency';
        $testargs->{args}{transfer_to} = $client_no_currency->loginid;
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account " . $client_no_currency->loginid, $test);
        reset_transfer_testargs();

        $mock_user_client->redefine(
            missing_requirements => sub {
                my $client = shift;
                return ('first_name', 'last_name') if ($client->loginid eq $Bob->loginid);
                return ();

            });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is_deeply $res->{error},
            {
            code              => 'PaymentAgentTransferError',
            details           => {fields => ['first_name', 'last_name']},
            message_to_client => "You cannot transfer to account $Bob_id, as their profile is incomplete."
            };
        $mock_user_client->unmock('missing_requirements');

        $test = 'Transfer fails if PA authentication documents are expired';
        $mock_documents->mock(expired => sub { shift->client->loginid eq $Alice_id ? 1 : 0 });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            'Your identity documents have expired. Visit your account profile to submit your valid documents and unlock your cashier.', $test);

        $test = 'Transfer fails if client authentication documents are expired';
        $mock_documents->mock(expired => sub { shift->client->loginid eq $Bob_id ? 1 : 0 });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their verification documents have expired.", $test);
        $mock_documents->unmock('expired');

        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}, undef, 'successful transfer') or warn explain $res->{error};
        $test_amount += $amount_boost;
        reset_transfer_testargs();

        $test = 'Transfer works with a previously transfered client, when payment agents are suspended in the target country';
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}, undef, $test);
        $test_amount += $amount_boost;

        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

        $test = 'Transfer fails if payment agent is not authenticated';
        $Alice->payment_agent->status('suspended');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Your account needs to be authenticated to perform payment agent transfers.", $test);
        $Alice->payment_agent->status('authorized');
        $Alice->save;

        $test = 'Transfer fails if given currency does not match payment agent currency';
        my $alt_currency = first { $_ ne $test_currency } shuffle @fiat_currencies, @crypto_currencies;
        my $alt_amount   = (grep { $alt_currency eq $_ } @crypto_currencies) ? 1 : 10;
        $testargs->{args}{currency} = $alt_currency;
        $testargs->{args}{amount}   = $alt_amount;
        $res                        = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is(
            $res->{error}{message_to_client},
            "You cannot perform this action, as $alt_currency is not the default account currency for payment agent $Alice_id.",
            "$test ($alt_currency)"
        );
        reset_transfer_testargs();

        $test = 'Transfer fails if given currency does not match client default account currency';
        ## For this we need to bypass the payment_agent check as well
        $testargs->{args}{currency} = $alt_currency;
        $testargs->{args}{amount}   = $alt_amount;
        $Alice->payment_agent->currency_code($alt_currency);
        $Alice->payment_agent->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            "You cannot perform this action, as $alt_currency is not the default account currency for payment agent $Alice_id.", $test);
        $Alice->payment_agent->currency_code($test_currency);
        $Alice->payment_agent->save;
        reset_transfer_testargs();

        $test = 'Transfer fails if given currency does not match transfer_to client default account currency';
        ## Cannot change existing currency for a client, so we make a new transfer_to client
        my $dummy_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'dummy' . $test_currency . '@dummy.com'
        });
        my $dummy_user = BOM::User->create(
            email    => $dummy_client->{email},
            password => $hash_pwd,
        );

        $dummy_client->set_default_account($alt_currency);
        $testargs->{args}{transfer_to} = $dummy_client->loginid;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        my $dummy_id = $dummy_client->loginid;
        is($res->{error}{message_to_client},
            "You cannot perform this action, as $test_currency is not the default account currency for client $dummy_id.", $test);

        $testargs->{args}{dry_run} = 1;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is(
            $res->{error}{message_to_client},
            "You cannot perform this action, as $test_currency is not the default account currency for client $dummy_id.",
            "$test - dry run"
        );

        reset_transfer_testargs();

        $test = 'Transfer fails when amount is over available funds due to frozen free gift limit';
        my $clientdbh = $Alice->dbh;
        my $SQL       = 'INSERT INTO betonmarkets.promo_code(code, description, promo_code_type, promo_code_config) VALUES(?,?,?,?)
                         ON CONFLICT (code) DO UPDATE SET promo_code_config = EXCLUDED.promo_code_config';
        my $sth_insert_promo  = $clientdbh->prepare($SQL);
        my $promo_amount      = $Alice_balance;
        my $promo_code_config = qq!{"apples_turnover":"100","amount":"$promo_amount"}!;
        $sth_insert_promo->execute('TEST1234', 'Test only', 'FREE_BET', $promo_code_config);
        $SQL = 'INSERT INTO betonmarkets.client_promo_code (client_loginid, promotion_code, status, mobile) VALUES (?,?,?,?)';
        my $sth_insert_client_promo = $clientdbh->prepare($SQL);
        $sth_insert_client_promo->execute($Alice_id, 'TEST1234', 'NOT CLAIMED', 'PA6-5000');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        my $bal = $Alice->default_account->balance;
        is($res->{error}{message_to_client},
            "Withdrawal is " . sprintf('%0.*f', $precision, $test_amount) . " $test_currency but balance $bal includes frozen bonus $bal.", $test);
        $SQL = 'DELETE FROM betonmarkets.client_promo_code WHERE client_loginid = ?';
        $clientdbh->do($SQL, undef, $Alice_id);
        $Alice->client_promo_code(undef);
        $Alice->save;
        reset_transfer_testargs();

        # push payment agent's email into exclusion list
        push @$payment_agent_exclusion_list, $Alice->email;
        $test          = q{payment agent is in exclusion list, transfer is allowed even if country of residence is different.};
        $old_residence = $Alice->residence;
        $Alice->residence('in the Wonder Land');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 1, $test);

        $Alice->residence($old_residence);
        $Alice->save;
        pop @$payment_agent_exclusion_list;
        $test_amount += $amount_boost;
        reset_transfer_testargs();

        ##
        ## Landing company limit testing
        ##
        $test = 'Transfer fails if amount is over the lifetime limit for landing company svg';
        my $lc_short = $Alice->landing_company->short;
        my $wd       = convert_currency($payment_withdrawal_limits->{$lc_short}, 'USD', $test_currency) - $test_amount + $amount_boost;
        $mock_account->mock('total_withdrawals' => $wd);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);

        like($res->{error}{message_to_client}, qr/You've reached the maximum withdrawal limit/, $test);

        undef $emitted_events;
        $mock_user_client->mock(fully_authenticated => 1);
        $test = 'OK when client if fully authenticated';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}, undef, $test);

        cmp_deeply(
            $emitted_events->{pa_transfer_confirm},
            [{
                    amount        => formatnumber('amount', $test_currency, $test_amount),
                    client_name   => $Bob->first_name . ' ' . $Bob->last_name,
                    currency      => $test_currency,
                    email         => $Alice->email,
                    language      => undef,
                    loginid       => $Bob->loginid,
                    pa_first_name => $Alice->first_name,
                    pa_last_name  => $Alice->last_name,
                    pa_loginid    => $Alice->loginid,
                    pa_name       => $Alice->payment_agent->payment_agent_name,
                }
            ],
            "pa_transfer_confirm event emitted"
        );

        cmp_deeply(
            $emitted_events->{payment_deposit},
            [{
                    amount             => formatnumber('amount', $test_currency, $test_amount),
                    currency           => $test_currency,
                    gateway_code       => "payment_agent_transfer",
                    is_agent_to_client => 1,
                    is_first_deposit   => $Bob->is_first_deposit_pending,
                    loginid            => $Bob->loginid,
                }
            ],
            "payment_deposit event emitted"
        );

        cmp_deeply(
            $emitted_events->{payment_withdrawal},
            [{
                    amount             => formatnumber('amount', $test_currency, $test_amount),
                    currency           => $test_currency,
                    gateway_code       => "payment_agent_transfer",
                    is_agent_to_client => 1,
                    loginid            => $Alice->loginid,
                }
            ],
            "payment_withdrawal event emitted"
        );

        $mock_user_client->unmock('fully_authenticated');
        $mock_account->unmock('total_withdrawals');
        $test_amount += $amount_boost;
        reset_transfer_testargs();

        # Not all scenarios of $client->validate_payment are covered above, full coverage is in bom-user tests

        $test = 'Transfer fails when request is too frequent';
        ## First time works, second gets the error:
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Request too frequent/, $test);
        reset_payment_limit_config();
        reset_payment_agent_config();
        reset_transfer_testargs();

    };

} ## end each type of currency for paymentagent_transfer

$mock_cashier->unmock('paymentagent_withdraw') if $mock_cashier->is_mocked('paymentagent_withdraw');

##
## Test of 'rpc paymentagent_withdraw' in Cashier.pm
##

## Transfer money from a person (client Alice) to a payment agent (Bob)

## https://github.com/regentmarkets/binary-websocket-api/blob/master/config/v3/paymentagent_withdraw/send.json
## paymentagent_withdraw arguments:
## 'client': [BOM::User::Client object] money FROM; a normal client account
## 'args' : [hashref] everything else below
##   'payment_withdraw': [integer] must be "1"
##   'paymentagent_loginid': [string] (loginid) money TO; the payment agent account
##   'currency': [string]
##   'amount': [number]
##   'verification_code': [string]
##   'description': [string]
##   'dry_run': [boolean]

sub reset_withdraw_testargs {
    $testargs = {
        client => $Alice,
        args   => {
            payment_withdraw     => 1,
            paymentagent_loginid => $Bob_id,
            currency             => $test_currency,
            amount               => $test_amount,
            verification_code    => 'dummy',
            description          => 'Testing',
            dry_run              => $dry_run,
        }};
    return;
}

## Cut and paste safety measure:
$mock_cashier->mock(
    'paymentagent_transfer',
    sub {
        my $line = (caller)[2];
        die "Wrong paymentagent function called at line $line: this is the withdraw section!\n";
    });

$mock_cashier->unmock('paymentagent_withdraw') if $mock_cashier->is_mocked('paymentagent_withdraw');

for my $withdraw_currency (shuffle @crypto_currencies, @fiat_currencies) {

    $test_currency = $withdraw_currency;
    my $precision = (grep { $_ eq $test_currency } @crypto_currencies) ? 8 : 2;
    $test_amount = (grep { $_ eq $test_currency } @crypto_currencies) ? 0.003 : 101;
    # crypto currencies can change with size 0.001, and fiat currencies can change with size 1
    my $amount_boost = (grep { $_ eq $test_currency } @crypto_currencies) ? 0.001 : 1;
    $dry_run = 1;

    my $email    = 'abc3' . rand . '@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::User::Password::hashpw($password);

    my $user = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    my $broker = 'CR';
    $Alice = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
    });
    $Alice_id = $Alice->loginid;

    $user->add_client($Alice);

    $email = 'abc4' . rand . '@binary.com';
    $user  = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $Bob = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
    });
    $Bob_id = $Bob->loginid;

    $user->add_client($Bob);

    diag "Withdraw currency is $test_currency. Created Alice as $Alice_id and Bob as $Bob_id";

    reset_withdraw_testargs();

    subtest "paymentagent_withdraw $test_currency" => sub {

        $Alice->set_default_account($test_currency);
        $Bob->set_default_account($test_currency);
        $payment_agent_args->{currency_code} = $test_currency;
        $mock_landingcompany->redefine('is_currency_legal' => 1);
        # make him payment agent
        $Bob->payment_agent($payment_agent_args);
        $Bob->save;
        # set countries for payment agent
        $Bob->get_payment_agent->set_countries(['id', 'in']);

        $test               = 'Withdraw fails if client has a virtual broker';
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $res                = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{code}, 'PaymentAgentWithdrawError', $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if given an invalid amount';
        for my $badamount (qw/ abc 1.2.3 1;2 . /) {
            $testargs->{args}{amount} = $badamount;
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            is($res->{error}{message_to_client}, 'Invalid amount.', "$test ($badamount)");
        }

        ## Precisions can be viewed via Format::Util::Numbers::get_precision_config();
        ## These checks rely on a local YAML file (e.g. 'precision.yml')
        for my $currency (@crypto_currencies, @fiat_currencies) {
            $testargs->{args}{currency} = $currency;
            my $precision = (grep { $_ eq $currency } @crypto_currencies) ? 8 : 2;
            $testargs->{args}{amount} = '1.2' . ('0' x $precision) . '1';
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            like(
                $res->{error}{message_to_client},
                qr/Invalid amount.* $precision decimal places/,
                "$test ($currency must be <= $precision decimal places)"
            );
        }
        reset_withdraw_testargs();

        $test = 'Withdraw failure gives the expected error code (PaymentAgentTransferError)';
        ## Quick check at least this one time. This code should not change.
        is($res->{error}{code}, 'PaymentAgentWithdrawError', $test);

        $test = 'Withdraw fails if all payments are suspended';
        $runtime_system->suspend->payments(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payments(0);

        $test = 'Withdraw fails if all payment_agents are suspended';
        $runtime_system->suspend->payment_agents(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payment_agents(0);

        $test = 'Withdraw fails if payment agent facility not available';
        ## Right now only CR offers payment agents according to:
        ## /home/git/regentmarkets/cpan/local/lib/perl5/auto/share/dist/LandingCompany/landing_companies.yml
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MF'});
        $user->add_client($testargs->{client});
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent facility is not available/, $test);
        reset_withdraw_testargs();

        $test = 'withdrawal fails if no_withdrawal_or_trading status is set';
        $Alice->status->set('no_withdrawal_or_trading', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.', $test);
        $Alice->status->clear_no_withdrawal_or_trading;
        $Alice->save;

        $test               = 'Withdraw fails if both sides are the same account';
        $testargs->{client} = $Bob;
        $res                = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'You cannot withdraw funds to the same account.', $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client has no residence';
        my $old_residence = $Alice->residence;
        $Alice->residence('');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Please set your country of residence./, $test);
        $Alice->residence($old_residence);
        $Alice->save;

        $test          = q{Withdraw fails if payment agent facility not allowed in client's country};
        $old_residence = $Alice->residence;
        $Alice->residence('pk');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client},
            qr/We're unable to process this withdrawal because your country of residence is not within the payment agent's portfolio./, $test);
        $Alice->residence($old_residence);
        $Alice->save;

        $test = 'Withdraw fails if client status = disabled';
        $Alice->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account ' . $Alice->loginid . ' is currently disabled.', $test);
        $Alice->status->clear_disabled;
        $Alice->save;

        $test = 'Withdraw fails if payment agent does not exist';
        $mock_client_paymentagent->mock('new', sub { return ''; });
        $testargs->{args}{paymentagent_loginid} = 'NOSUCHUSER';
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'Please enter a valid payment agent ID.', $test);
        $mock_client_paymentagent->unmock('new');
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client and payment agent have different brokers';
        ## Problem: Only CR currently allows payment agents, so we have to use a little trickery
        $mock_user_client->redefine(broker => sub { shift->loginid eq $Bob_id ? 'MF' : 'CR' });
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/withdrawals are not allowed for specified accounts/, $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $mock_user_client->unmock('broker');

        $test = 'Withdraw fails if client default account has wrong currency';
        my $alt_currency = first { $_ ne $test_currency } shuffle @fiat_currencies, @crypto_currencies;
        ## We have to mock because if set direct it is caught early by User::Client
        $mock_account->redefine('currency_code', sub { return $_[0]->client_loginid eq $Alice_id ? $alt_currency : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/as $test_currency is not default currency for your account $Alice_id/, $test);
        $mock_account->unmock('currency_code');

        $test = 'Withdraw fails if payment agent default account has wrong currency';
        $mock_account->redefine('currency_code', sub { return $_[0]->client_loginid eq $Bob_id ? $alt_currency : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/as $test_currency is not default currency for payment agent account $Bob_id/, $test);
        $mock_account->unmock('currency_code');

        $test                     = 'Transfer fails if amount is under the payment agent minimum';
        $testargs->{args}{amount} = (grep { $test_currency eq $_ } @crypto_currencies) ? 0.001 : 1.0;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is [\d\.]+, maximum is \d+/, $test);
        reset_withdraw_testargs();

        $test                     = 'Transfer fails if amount is over the payment agent maximum';
        $testargs->{args}{amount} = (grep { $test_currency eq $_ } @crypto_currencies) ? 10 : 10_000;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is [\d\.]+, maximum is \d+/, $test);
        reset_withdraw_testargs();

        $test                          = "Withdraw fails if description is over $MAX_DESCRIPTION_LENGTH characters";
        $testargs->{args}{description} = 'A' x (1 + $MAX_DESCRIPTION_LENGTH);
        $res                           = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/instructions must not exceed $MAX_DESCRIPTION_LENGTH/, $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client status = cashier_locked';
        $Alice->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/cashier is locked/, $test);
        $Alice->status->clear_cashier_locked;
        $Alice->save;

        $test = 'Withdraw fails if client status = withdrawal_locked';
        $Alice->status->set('withdrawal_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account is withdrawal locked.', $test);
        $Alice->status->clear_withdrawal_locked;
        $Alice->save;

        # this test assume address_city is a withdrawal requirement for SVG in landing_companies.yml
        $Alice->address_city('');
        $Alice->save;
        $test = 'Withdraw fails if missing address_city';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        $Alice->address_city('Beverly Hills');
        $Alice->save;

        $test = 'Withdraw fails if client authentication documents are expired';
        $auth_document_args->{expiration_date} = '1999-12-31';
        my ($doc) = $Alice->add_client_authentication_document($auth_document_args);
        $Alice->save;

        # force to reload documents
        undef $Alice->{documents};

        $mock_user_client->mock('is_poi_expiration_check_required', sub { 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your identity documents have expired/, $test);
        $mock_user_client->unmock('is_poi_expiration_check_required');

        $test = 'Withdraw fails if payment agent status = disabled';
        my $clientdbh   = $Alice->dbh;
        my $SQL         = 'UPDATE betonmarkets.client_authentication_document SET expiration_date = ? WHERE client_loginid = ?';
        my $sth_doc_exp = $clientdbh->prepare($SQL);
        $sth_doc_exp->execute('2999-02-25', $Alice_id);
        ## Need Rose to pick the DB changes up
        $testargs->{client} = $Alice = BOM::User::Client->new({loginid => $Alice_id});
        $Bob->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/payment agent's account is disabled/, $test);
        $Bob->status->clear_disabled;
        $Bob->save;

        $test = 'Withdraw fails if payment agent status = unwelcome';
        $Bob->status->set('unwelcome', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{code}, 'PaymentAgentWithdrawError', $test);
        $Bob->status->clear_unwelcome;
        $Bob->save;

        $test = 'Withdraw fails if payment agent status = cashier_locked';
        $Bob->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/payment agent's cashier is locked/, $test);
        $Bob->status->clear_cashier_locked;
        $Bob->save;

        $test = 'Withdraw fails if payment agent authentication documents are expired';
        $auth_document_args->{expiration_date} = '1999-02-24';
        ($doc) = $Bob->add_client_authentication_document($auth_document_args);
        $Bob->save;
        $mock_user_client->mock('is_poi_expiration_check_required', sub { 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/documents have expired/, $test);
        $mock_user_client->unmock('is_poi_expiration_check_required');
        $sth_doc_exp->execute('2999-02-25', $Bob_id);
        ## Need Rose to pick the DB changes up
        $Bob  = BOM::User::Client->new({loginid => $Bob_id});
        $test = 'Withdraw returns correct paymentagent_name when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{paymentagent_name}, $agent_name, $test);

        $test = 'Withdraw returns correct status of 2 when dry_run is set';
        is($res->{status}, 2, $test);
        $dry_run = 0;
        $mock_utility->mock('is_verification_token_valid', sub { return {status => 1} });
        reset_withdraw_testargs();

        $test = 'Withdrawal fails if payment agents are suspended in the target country';
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, "Payment agent transfers are temporarily unavailable in the client's country of residence.", $test);
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

        $test = 'Withdraw fails if client is internal';
        $Alice->status->setnx('internal_client', 'system', 'test');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, "This feature is not allowed for internal clients.", $test);
        $Alice->status->clear_internal_client;

        ## (validate_payment)

        $test = 'Withdrawal fails if amount exceeds client balance';
        my $Alice_balance = $Alice->default_account->balance;
        my $alt_amount    = $test_amount * 2;
        $testargs->{args}{amount} = $alt_amount;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        my $balance = $Alice->default_account ? formatnumber('amount', $test_currency, $Alice_balance) : 0;
        ## Cashier.pm does some remapping to Payments.pm
        like($res->{error}{message_to_client}, qr/account has zero balance/, $test);
        top_up $Alice, $test_currency => $MAX_DAILY_WITHDRAW_AMOUNT_WEEKDAY + 1;    ## Should work for all currencies

        $mock_account->mock('total_withdrawals', sub { return 54321 });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/reached the maximum withdrawal limit/, 'reached maximum withdrawal limit');
        $mock_account->unmock('total_withdrawals');

        ## These limits only make sense for USD, although all currencies are checked?!?
        if ($test_currency eq 'USD') {

            $test = 'Withdraw fails if amount requested is over withdrawal to date limit (weekday)';
            my $currency_type = LandingCompany::Registry::get_currency_type($test_currency);    ## e.g. "fiat"
            my $agent_info    = BOM::Config::payment_agent();
            my $old_max       = $agent_info->{payment_limits}{$currency_type}{maximum};
            $agent_info->{payment_limits}{$currency_type}{maximum} = 999_999;
            $testargs->{args}{amount} = $MAX_DAILY_WITHDRAW_AMOUNT_WEEKDAY + 1;
            $mock_date_utility->mock('is_a_weekend', sub { return 0; });
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            my $show_amount = formatnumber('amount', 'USD', $MAX_DAILY_WITHDRAW_AMOUNT_WEEKDAY);
            like($res->{error}{message_to_client}, qr/transfer amount USD $show_amount for today/, $test);

            $test = 'Withdraw fails if amount requested is over withdrawal to date limit (weekend)';
            $testargs->{args}{amount} = $MAX_DAILY_WITHDRAW_AMOUNT_WEEKEND + 1;
            $mock_date_utility->mock('is_a_weekend', sub { return 1; });
            $res         = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            $show_amount = formatnumber('amount', 'USD', $MAX_DAILY_WITHDRAW_AMOUNT_WEEKEND);
            like($res->{error}{message_to_client}, qr/transfer amount USD $show_amount for today/, $test);
            $agent_info->{payment_limits}{$currency_type}{maximum} = $old_max;
            $mock_date_utility->unmock('is_a_weekend');
            reset_withdraw_testargs();

        }

        ## We will assume this one is for all currencies, despite coming after the above:
        $test = "Withdraw fails if over maximum transactions per day ($MAX_DAILY_WITHDRAW_TXNS_WEEKDAY)";
        $mock_user_client->redefine('today_payment_agent_withdrawal_sum_count', sub { return 0, $MAX_DAILY_WITHDRAW_TXNS_WEEKDAY * 3; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/allowable transactions for today/, $test);
        $mock_user_client->unmock('today_payment_agent_withdrawal_sum_count');

        # mock to make sure that there is authenticated pa in Alice's country
        $mock_payment_agent->redefine('get_authenticated_payment_agents', sub { return {pa1 => 'dummy'}; });
        # push payment agent's email into exclusion list
        push @$payment_agent_exclusion_list, $Alice->email;
        $test          = q{payment agent is in exclusion list, withdraw is allowed even if country of residence is different.};
        $old_residence = $Alice->residence;
        $Alice->residence('in the Wonder Land');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{status}, 1, $test);
        $Alice->residence($old_residence);
        pop @$payment_agent_exclusion_list;
        $mock_payment_agent->unmock('get_authenticated_payment_agents');
        $test_amount = sprintf('%0.*f', $precision, $test_amount + $amount_boost);
        reset_withdraw_testargs();

        undef $emitted_events;
        $test = 'Withdraw returns correct paymentagent_name when dry_run is off';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{paymentagent_name}, $agent_name, $test);

        $test = 'Withdraw returns correct status of 1 when dry_run is off';
        is($res->{status}, 1, $test);

        cmp_deeply(
            $emitted_events->{pa_withdraw_confirm},
            [{
                    amount         => formatnumber('amount', $test_currency, $test_amount),
                    client_loginid => $Alice->loginid,
                    client_name    => $Alice->first_name . ' ' . $Alice->last_name,
                    currency       => $test_currency,
                    email          => $Bob->email,
                    language       => undef,
                    loginid        => $Bob->loginid,
                    pa_first_name  => $Bob->first_name,
                    pa_last_name   => $Bob->last_name,
                    pa_loginid     => $Bob->loginid,
                    pa_name        => $Bob->full_name,
                }
            ],
            "pa_withdraw_confirm event emitted"
        );

        cmp_deeply(
            $emitted_events->{payment_deposit},
            [{
                    amount             => formatnumber('amount', $test_currency, $test_amount),
                    currency           => $test_currency,
                    gateway_code       => "payment_agent_transfer",
                    is_agent_to_client => 0,
                    is_first_deposit   => 0,
                    loginid            => $Bob->loginid,
                }
            ],
            "payment_deposit event emitted"
        );

        cmp_deeply(
            $emitted_events->{payment_withdrawal},
            [{
                    amount             => formatnumber('amount', $test_currency, $test_amount),
                    currency           => $test_currency,
                    gateway_code       => "payment_agent_transfer",
                    is_agent_to_client => 0,
                    loginid            => $Alice->loginid,
                }
            ],
            "payment_withdrawal event emitted"
        );

        $test = 'Withdraw fails when request is too frequent';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Request too frequent/, $test);

        $test = 'Withdrawal works for previously transfered payment agents even in a suspended country (dry run to avoid sleeping)';
        $testargs->{args}->{dry_run} = 1;
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}, undef, $test);
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
        $testargs->{args}->{dry_run} = 0;

        $test_amount = sprintf('%0.*f', $precision, $test_amount + $amount_boost);
        reset_withdraw_testargs();

        # mock to make sure that there is authenticated pa in Alice's country
        $mock_payment_agent->mock('get_authenticated_payment_agents', sub { return {pa1 => 'dummy'}; });
        $test          = q{You can withdraw from payment agent of different residence};
        $old_residence = $Alice->residence;
        $Alice->residence('in');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{status}, 1, $test) or diag Dumper $res;
        $Alice->residence($old_residence);
        $mock_payment_agent->unmock('get_authenticated_payment_agents');

        ## Cleanup:
        $mock_utility->unmock('is_verification_token_valid');
        $mock_landingcompany->unmock('is_currency_legal');
    };

} ## end of each test_currency type

$mock_cashier->unmock('paymentagent_transfer');

done_testing();

sub reset_payment_agent_config {
    ## In-place modification of the items returned by BOM::Config
    ## This is needed as mocking and clone/dclone do not work well, due to items declared as 'state'
    ## We assume all config items are "hashes all the way down"

    my $funcname = 'payment_agent';
    BOM::Config->can($funcname) or die "Sorry, BOM::Config does not have a function named '$funcname'";

    my $config = BOM::Config->$funcname;
    ref $config eq 'HASH' or die "BOM::Config->$funcname is not a hash?!\n";

    reset_config($config);

    return;
}

sub reset_payment_limit_config {
    ## In-place modification of the items returned by Business::Config::LandingCompany
    ## This is needed as mocking and clone/dclone do not work well, due to items declared as 'state'
    ## We assume all config items are "hashes all the way down"

    my $funcname = 'payment_limit';
    Business::Config::LandingCompany->can($funcname) or die "Sorry, Business::Config::LandingCompany does not have a function named '$funcname'";

    my $config = Business::Config::LandingCompany->new()->$funcname;
    ref $config eq 'HASH' or die "Business::Config::LandingCompany->$funcname is not a hash?!\n";

    reset_config($config);

    return;
}

sub reset_config {
    my $config = shift;

    return if !ref $config;

    for my $key (keys %$config) {
        reset_config($config->{$key}) if ref $config->{$key};
        if ($key =~ /^OLD_(.+)/) {
            $config->{$1} = delete $config->{$key};
        }
    }

    return;
}
