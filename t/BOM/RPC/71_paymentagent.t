#!/usr/bin/perl

## Test of 'paymentagent_transfer' and 'paymentagent_withdraw'

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::MockModule;
use Clone qw( clone );
use List::Util qw( first shuffle );
use YAML::XS;
use Data::Dumper;

use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );
use BOM::Test::Helper::Client qw( top_up );
use ExchangeRates::CurrencyConverter qw( convert_currency );
use Format::Util::Numbers qw( formatnumber );

my ($Alice, $Alice_id, $Bob, $Bob_id, $test, $test_currency, $test_amount, $dry_run, $testargs, $res);

my @crypto_currencies = qw/ BCH BTC ETH LTC /;    ## ETC not enabled for CR landing company
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
    url                   => 'http://www.example.com/',
    email                 => 'joe@example.com',
    phone                 => '+12345678',
    information           => 'Test Info',
    summary               => 'Test Summary',
    commission_deposit    => 0,
    commission_withdrawal => 0,
    is_authenticated      => 't',
    target_country        => 'id',
};

## For client authentication document tests.
## The expiration_date is left out on purpose and should be explicitly set each time.
my $auth_document_args = {
    document_type              => 'passport',
    document_format            => 'TST',
    document_path              => '/tmp/testfile2.tst',
    authentication_method_code => 'TESTY_TESTY',
    status                     => 'uploaded',
    checksum                   => 'Abcder12345678'
};

## Used for test safety, and to mock_get_amount_and_count:
my $mock_cashier = Test::MockModule->new('BOM::RPC::v3::Cashier');

## Used to mock 'freeze':
my $mock_clientdb = Test::MockModule->new('BOM::Database::ClientDB');

## Used to mock default_account, payment_account_transfer, landing_company, currency:
my $mock_user_client = Test::MockModule->new('BOM::User::Client');

## (Don't ever send an email out when a client is created)
$mock_user_client->mock('add_note', sub { return 1 });
## We do not want to worry about this right now:
$mock_user_client->mock('is_tnc_approval_required', sub { return 0; });

## Used to simulate a payment agent not existing:
my $mock_client_paymentagent = Test::MockModule->new('BOM::User::Client::PaymentAgent');

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

## Used to force non-costarica landing companies to allow payment agents:
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
my $payment_withdrawal_limits = BOM::Config->payment_limits()->{withdrawal_limits};
my $payment_transfer_limits   = BOM::Config::payment_agent()->{transaction_limits}->{transfer};

## Global binary_user_id
my $bid = 12345;

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

    $test_amount = (grep { $_ eq $test_currency } @crypto_currencies) ? '0.00200000' : '100.40';
    my $amount_boost = (grep { $_ eq $test_currency } @crypto_currencies) ? '0.001' : 100;
    my $precision    = (grep { $_ eq $test_currency } @crypto_currencies) ? 8       : 2;

    ## Create brand new clients for each loop
    my $broker = 'CR';
    $Alice = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
        first_name  => 'Alice'
    });
    $Alice_id = $Alice->loginid;
    $Alice->set_default_account($test_currency);

    $Bob = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => $broker,
        first_name  => 'Bob'
    });
    $Bob_id = $Bob->loginid;
    $Bob->set_default_account($test_currency);

    diag "Transfer currency is $test_currency. Created Alice as $Alice_id and Bob as $Bob_id";

    $dry_run = 1;
    reset_transfer_testargs();

    subtest "paymentagent_transfer $test_currency" => sub {

        $test = 'Client account starts with a zero balance';
        is($Alice->default_account->balance, 0, $test) or BAIL_OUT $test;

        $test = 'Transfer_to account starts with a zero balance';
        is($Bob->default_account->balance, 0, $test) or BAIL_OUT $test;

        ## In rough order of the code in Cashier.pm

        $test = 'Transfer fails if client has a virtual broker (VRTC)';
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Permission denied.', $test);
        reset_transfer_testargs();

        ##
        ## Tests for _validate_amount in Cashier.pm
        ##

        $test = 'Transfer fails if given an invalid amount';
        ## Cashier->_validate_amount declares that amounts must be: /^(?:\d+\.?\d*|\.\d+)$/
        for my $bad_amount (qw/ abc 1e80 1.2.3 1;2 . /) {
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
            $testargs->{args}{amount} = '1.2' . ('0' x $local_precision);
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

        $test = 'Transfer fails if client landing company does not allow payment agents';
        ## This check relies on a local YAML file (e.g. 'landing_companies.yml')
        ## Only CR allows payment agents currently, so we mock the result here
        $mock_landingcompany->mock('allows_payment_agents', sub { return 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'The payment agent facility is not available for this account.', $test);
        $mock_landingcompany->unmock('allows_payment_agents');

        $test = 'Transfer fails if client has no payment agent';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You are not authorized for transfers via payment agents.', $test);

        $test = 'Transfer fails is amount is over the landing company maximum';
        $payment_agent_args->{currency_code} = $test_currency;
        $Alice->payment_agent($payment_agent_args);
        my $currency_type = LandingCompany::Registry::get_currency_type($test_currency);      ## e.g. "fiat"
        my $lim           = BOM::Config::payment_agent()->{payment_limits}{$currency_type};
        my $max           = $lim->{maximum};
        $testargs->{args}{amount} = $max * 2;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Maximum withdrawal allowed is $max.", "$test ($max for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is over the payment agent maximum';
        ## These two checks rely on a local YAML file (e.g. 'landing_companies.yml')
        my $max_amount = $test_amount / 2;
        $Alice->payment_agent->max_withdrawal($max_amount);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Maximum withdrawal allowed is $max_amount.", $test);
        $Alice->payment_agent->max_withdrawal(undef);

        $test = 'Transfer fails is amount is under the landing company minimum';
        my $min = $lim->{minimum};
        $testargs->{args}{amount} = $min * 0.5;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum withdrawal allowed is $min.", "$test ($min for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is under the payment agent minimum';
        my $min_amount = $test_amount * 2;
        $Alice->payment_agent->min_withdrawal($min_amount);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Invalid amount. Minimum withdrawal allowed is $min_amount.", $test);
        $Alice->payment_agent->min_withdrawal(undef);

        $test = 'Transfer fails if missing required details (place_of_birth)';
        $Alice->place_of_birth('');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        $Alice->place_of_birth('id');
        $Alice->save;

        $test = "Withdraw fails if description is over $MAX_DESCRIPTION_LENGTH characters";
        $testargs->{args}{description} = 'A' x (1 + $MAX_DESCRIPTION_LENGTH);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Notes must not exceed $MAX_DESCRIPTION_LENGTH/, $test);
        reset_withdraw_testargs();

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
                return LandingCompany::Registry->get_by_broker($_[0]->loginid eq $Alice_id ? 'MLT' : 'CR');
            });

        ## Then we need to declare that Malta can have payment agents too
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Payment agent transfers are not allowed for the specified accounts.', $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $mock_user_client->unmock('landing_company');

        $test = q{You cannot transfer to client of different residence};
        my $old_residence = $Alice->residence;
        $Alice->residence('in the Wonder Land');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/You cannot transfer to a client in a different country of residence./, $test);
        $Alice->residence($old_residence);

        $test = 'Transfer fails if payment agents are suspended in the target country';
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Payment agent transfers are temporarily unavailable in the client's country of residence.", $test);
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

        $test = 'Transfer returns a status of 2 when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 2, $test) or diag Dumper $res;

        $test = 'Transfer returns correct transfer_to client full name when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{client_to_full_name}, $Bob->full_name, $test) or diag Dumper $res;
        $test = 'Transfer works and returns correct transfer_to client loginid when dry_run is set';
        is($res->{client_to_loginid}, $Bob_id, $test);

        $test = 'After transfer with dry_run, client account has an unchanged balance';
        is($Alice->default_account->balance, 0, $test);

        $test = 'After transfer with dry_run, transfer_to client account has an unchanged balance';
        is($Bob->default_account->balance, 0, $test);

        $test = "Transfer fails if over maximum amount per day (USD $MAX_DAILY_TRANSFER_AMOUNT_USD)";
        ## From this point on, we cannot have dry run enabled
        $dry_run = 0;
        reset_transfer_testargs();
        ## Technically, the mock should return that limit in the test_currency, but this large value covers it
        $mock_cashier->mock('_get_amount_and_count', sub { return $MAX_DAILY_TRANSFER_AMOUNT_USD * 99, 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            'Payment agent transfers are not allowed, as you have exceeded the maximum allowable transfer amount for today.', $test);
        $mock_cashier->unmock('_get_amount_and_count');

        $test = "Transfer fails is over the maximum transactions per day (USD $MAX_DAILY_TRANSFER_AMOUNT_USD)";
        $mock_cashier->mock('_get_amount_and_count', sub { return 0, $MAX_DAILY_TRANSFER_TXNS * 55; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            'Payment agent transfers are not allowed, as you have exceeded the maximum allowable transactions for today.', $test);
        $mock_cashier->unmock('_get_amount_and_count');

        ##
        ## At this point in Cashier.pm, we call payment_account_transfer, so we need some funds
        ##

        $test = 'Client account has correct balance after top up';
        ## We need enough to cover all the following tests, which start with $test_amount,
        ## and increaase by $amount_boost after each successful transfer. Thus the '15'
        my $Alice_balance = sprintf('%0.*f', $precision, $test_amount * 15);
        top_up $Alice, $test_currency => $Alice_balance;
        ## This is used to keep a running tab of amount transferred:
        my $Alice_transferred = 0;
        is($Alice->default_account->balance, $Alice_balance, "$test ($test_currency $Alice_balance)");

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

        ## We now are checking the database function payment.payment_account_transfer()
        ## The actual database function is payment.local_payment_account_transfer()
        ## It performs validations by a call to payment.validate_paymentagent_transfer()
        $test                          = 'Transfer fails if we try to transfer from and to the same account';
        $testargs->{args}{transfer_to} = $Alice_id;
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Payment agent transfers are not allowed within the same account.', $test);
        reset_transfer_testargs();

        ## Skip validations that both client_ids exist. Caught before the database function is called.

        ## Skip check that client account is not virtual - handled in Cashier.pm

        $test = 'Transfer fails if client cashier has a password';
        $Alice->cashier_setting_password('yin');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Your cashier is locked as per your request.', $test);
        $Alice->cashier_setting_password('');
        $Alice->save;

        $test = 'Transfer fails if transfer_to client cashier has a password';
        $Bob->cashier_setting_password('yang');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their cashier is locked.", $test);
        $Bob->cashier_setting_password(undef);
        $Bob->save;

        $test = 'Transfer fails if client status = cashier_locked';
        $Alice->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account is cashier locked.', $test);
        $Alice->status->clear_cashier_locked;
        $Alice->save;

        $test = 'Transfer fails if client status = disabled';
        $Alice->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your account is currently disabled.', $test);
        $Alice->status->clear_disabled;
        $Alice->save;

        $test = 'Transfer fails if client status = withdrawal_locked';
        $Alice->status->set('withdrawal_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'Withdrawal is disabled.', $test);
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
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their account is currently disabled.", $test);
        $Bob->status->clear_disabled;
        $Bob->save;

        $test = 'Transfer fails if transfer_to client status = unwelcome';
        $Bob->status->set('unwelcome', 'Testy McTestington', 'Just running some tests');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their account is marked as unwelcome.", $test);
        $Bob->status->clear_unwelcome;
        $Bob->save;

        $test = 'Transfer fails if all client authentication documents are expired';
        $auth_document_args->{expiration_date} = '1999-12-31';
        $Alice->add_client_authentication_document($auth_document_args);
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, 'You cannot perform this action, as your verification documents have expired.', $test);

        $test = 'Transfer works if only one client authentication documents is expired';
        $auth_document_args->{expiration_date} = '2999-12-31';
        $Alice->add_client_authentication_document($auth_document_args);
        $Alice->save;
        $testargs->{args}->{description} = 'One document is expired';
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, undef, $test);
        $Alice_transferred += $test_amount;
        $Alice_balance = sprintf('%0.*f', $precision, $Alice_balance - $test_amount);
        my $Bob_balance = sprintf('%0.*f', $precision, $test_amount);
        ## Need to boost the test_amount to get around the frequency checks
        $test_amount = sprintf('%0.*f', $precision, $test_amount + $amount_boost);
        reset_transfer_testargs();

        $test =
            'Transfer works with a previously transfered client, when payment agents are suspended in the target country (dry run to avoid sleeping)';
        $testargs->{args}->{dry_run} = 1;
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}, undef, $test) or warn($res->{error});
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);
        $testargs->{args}->{dry_run} = 0;

        $test = 'Transfer fails if transfer_to client authentication documents are expired';
        $auth_document_args->{expiration_date} = '1999-12-31';
        $Bob->add_client_authentication_document($auth_document_args);
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "You cannot transfer to account $Bob_id, as their verification documents have expired.", $test);
        $auth_document_args->{expiration_date} = '2999-12-31';
        $Bob->add_client_authentication_document($auth_document_args);
        $Bob->save;

        ## Skip check that client has a payment agent: already done in Cashier.pm

        $test = 'Transfer fails if payment agent is not authenticated';
        $Alice->payment_agent->is_authenticated(0);
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Your account needs to be authenticated to perform payment agent transfers.", $test);
        $Alice->payment_agent->is_authenticated(1);
        $Alice->save;

        $test = 'Transfer fails if given currency does not match payment agent currency';
        my $alt_currency = first { $_ ne $test_currency } shuffle @fiat_currencies, @crypto_currencies;
        my $alt_amount = (grep { $alt_currency eq $_ } @crypto_currencies) ? 1 : 10;
        $testargs->{args}{currency} = $alt_currency;
        $testargs->{args}{amount}   = $alt_amount;
        ## We need to mock this, as going from fiat to crypto can boost our cumulative amounts sky high
        $mock_cashier->mock('_get_amount_and_count', sub { return 0, 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
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
            "You cannot perform this action, as $alt_currency is not the default account currency for client $Alice_id.", $test);
        $Alice->payment_agent->currency_code($test_currency);
        $Alice->payment_agent->save;
        reset_transfer_testargs();

        $test = 'Transfer fails if given currency does not match transfer_to client default account currency';
        ## Cannot change existing currency for a client, so we make a new transfer_to client
        my $dummy_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
        $dummy_client->set_default_account($alt_currency);
        $testargs->{args}{transfer_to} = $dummy_client->loginid;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        my $dummy_id = $dummy_client->loginid;
        is($res->{error}{message_to_client},
            "You cannot perform this action, as $test_currency is not the default account currency for client $dummy_id.", $test);
        $mock_cashier->unmock('_get_amount_and_count');
        reset_transfer_testargs();

        $test = 'Transfer fails when amount is over available funds due to frozen free gift limit';
        my $clientdbh = $Alice->dbh;
        my $SQL       = 'INSERT INTO betonmarkets.promo_code(code, description, promo_code_type, promo_code_config) VALUES(?,?,?,?)
                         ON CONFLICT (code) DO UPDATE SET promo_code_config = EXCLUDED.promo_code_config';
        my $sth_insert_promo  = $clientdbh->prepare($SQL);
        my $promo_amount      = 10 * $Alice_balance;
        my $promo_code_config = qq!{"apples_turnover":"100","amount":"$promo_amount"}!;
        $sth_insert_promo->execute('TEST1234', 'Test only', 'FREE_BET', $promo_code_config);
        $SQL = 'INSERT INTO betonmarkets.client_promo_code (client_loginid, promotion_code, status, mobile) VALUES (?,?,?,?)';
        my $sth_insert_client_promo = $clientdbh->prepare($SQL);
        $sth_insert_client_promo->execute($Alice_id, 'TEST1234', 'NOT CLAIMED', 'PA6-5000');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        my $bal = $Alice->default_account->balance;
        is($res->{error}{message_to_client}, "Withdrawal is $test_currency $test_amount but balance $bal includes frozen bonus $bal.", $test);
        $SQL = 'DELETE FROM betonmarkets.client_promo_code WHERE client_loginid = ?';
        $clientdbh->do($SQL, undef, $Alice_id);

        # push payment agent's email into exclusion list
        push @$payment_agent_exclusion_list, $Alice->email;
        $test          = q{payment agent is in exclusion list, transfer is allowed even if country of residence is different.};
        $old_residence = $Alice->residence;
        $Alice->residence('in the Wonder Land');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 1, $test);
        $Alice_transferred += $test_amount;
        $Alice->residence($old_residence);
        pop @$payment_agent_exclusion_list;

        # sleep 2 seconds to allow next pa transfer
        sleep 2;

        $test              = 'Transfer works when min_turnover overrides the frozen free gift limit check';
        $promo_code_config = qq!{"min_turnover":"100","amount":"$promo_amount"}!;
        $sth_insert_promo->execute('TEST1234', 'Test only', 'FREE_BET', $promo_code_config);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 1, $test);
        $Alice_transferred += $test_amount;
        $Alice_balance = sprintf('%0.*f', $precision, $Alice_balance - $test_amount * 2);    # * 2 because we performed 2 pa transfer
        $Bob_balance   = sprintf('%0.*f', $precision, $Bob_balance + $test_amount * 2);
        $test_amount   = sprintf('%0.*f', $precision, $test_amount + $amount_boost);
        reset_transfer_testargs();

        ##
        ## Landing company limit testing
        ##

        $test = 'Transfer fails if amount is over the lifetime limit for landing company costarica';
        ## For these tests, we need to know what the limits are:
        my $limit_transactions_per_day = $payment_transfer_limits->{transactions_per_day};
        my $limit_usd_per_day          = $payment_transfer_limits->{amount_in_usd_per_day};
        my $lc_short                   = $Alice->landing_company->short;
        my $test_lc_limits             = $payment_withdrawal_limits->{$lc_short};
        my ($lc_currency, $lc_lifetime_limit, $lc_for_days, $lc_limit_for_days) =
            @$test_lc_limits{qw/ currency  lifetime_limit  for_days  limit_for_days /};
        my $old_test_amount = $test_amount;
        $test_amount = convert_currency($lc_lifetime_limit + 2, 'USD', $test_currency);
        $test_amount = formatnumber('amount', $test_currency, $test_amount);
        $testargs->{args}{amount} = $test_amount;
        ## Make sure we have enough funds that we do not hit the balance limit:
        top_up $Alice, $test_currency => $test_amount;
        $Alice_balance += $test_amount;

        ## We need to prevent the earlier payment agent limit check inside from Cashier.pm from happening
        modify_bom_config('payment_agent', 'payment_limits/*/maximum = ' . $lc_lifetime_limit * 2);

        my $show_left = convert_currency($lc_lifetime_limit, 'USD', $test_currency);
        $show_left = formatnumber('amount', $test_currency, $show_left - $Alice_transferred);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is(
            $res->{error}{message_to_client},
            "Sorry, you cannot withdraw. Your withdrawal amount $test_currency $test_amount exceeds withdrawal limit $test_currency $show_left.",
            "$test ($lc_lifetime_limit)"
        );
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is over the lifetime limit for landing company costarica (limit not shown)';
        modify_bom_config('payment_limits', 'withdrawal_limits/*/lifetime_limit = 2');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client},
            "Sorry, you cannot withdraw. Your withdrawal amount $test_currency $test_amount exceeds withdrawal limit.", $test);
        reset_transfer_testargs();

        $test = 'Landing company limits are skipped if the client is fully authenticated';
        $SQL  = 'INSERT INTO betonmarkets.client_authentication_method
                (client_loginid, authentication_method_code, status, description)
                VALUES (?,?,?,?)';
        my $sth_add_method = $clientdbh->prepare($SQL);

        $sth_add_method->execute($Alice_id, 'ID_DOCUMENT', 'pass', 'Testing only');
        top_up $Alice, $test_currency => $test_amount;
        $Alice_balance += $test_amount;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, undef, $test);
        $Alice_transferred += $test_amount;
        $Alice_balance = sprintf('%0.*f', $precision, $Alice_balance - $test_amount);
        $Bob_balance   = sprintf('%0.*f', $precision, $Bob_balance + $test_amount);
        $test_amount   = sprintf('%0.*f', $precision, $test_amount + $amount_boost);
        reset_transfer_testargs();
        $SQL = 'DELETE FROM betonmarkets.client_authentication_method WHERE client_loginid = ?';
        my $sth_delete_method = $clientdbh->prepare($SQL);
        $sth_delete_method->execute($Alice_id);

        $test = 'Transfer fails if amount is over the lifetime limit for landing company champion';
        ## Same as above, but we force the landing company to be champion
        $mock_user_client->mock('landing_company', sub { return LandingCompany::Registry->get_by_broker('CH') });
        $lc_short       = $Alice->landing_company->short;
        $test_lc_limits = $payment_withdrawal_limits->{$lc_short};
        ($lc_currency, $lc_lifetime_limit) = @$test_lc_limits{qw/ currency lifetime_limit /};
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        ## As before, we carefully adjust our payment history
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is(
            $res->{error}{message_to_client},
            "Sorry, you cannot withdraw. Your withdrawal amount $test_currency $test_amount exceeds withdrawal limit.",
            "$test ($lc_lifetime_limit)"
        );

        $mock_user_client->unmock('landing_company');
        $mock_landingcompany->unmock('allows_payment_agents');
        reset_transfer_testargs();
        reset_transfer_testargs();

        $test = 'Transfer fails if amount is over the for_days limit for landing company iom';
        $mock_user_client->mock('landing_company', sub { return LandingCompany::Registry->get_by_broker('MX') });
        $lc_short       = $Alice->landing_company->short;
        $test_lc_limits = $payment_withdrawal_limits->{$lc_short};
        ($lc_currency, $lc_lifetime_limit, $lc_for_days, $lc_limit_for_days) = @$test_lc_limits{qw/ currency lifetime_limit for_days limit_for_days/};
        ## IOM has an insanely high lifetime limit, so we do not check it here
        ## We can check the for_days limit though
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is(
            $res->{error}{message_to_client},
            "Sorry, you cannot withdraw. Your withdrawal amount $test_currency $test_amount exceeds withdrawal limit.",
            "$test (for_days = $lc_limit_for_days)"
        );
        $mock_user_client->unmock('landing_company');
        $mock_landingcompany->unmock('allows_payment_agents');
        reset_transfer_testargs();

        $test = 'Going over landing company limits for iom triggers cashier_locked status for the client';
        $SQL  = 'SELECT * FROM betonmarkets.client_status WHERE client_loginid = ? AND status_code = ?';
        my $sth_client_status = $clientdbh->prepare($SQL);
        $sth_client_status->execute($Alice_id, 'cashier_locked');
        my $actual   = $sth_client_status->fetchall_arrayref({});
        my $expected = [{
                'client_loginid'     => $Alice_id,
                'staff_name'         => 'system',
                'status_code'        => 'cashier_locked',
                'reason'             => 'Exceeds withdrawal limit',
                'id'                 => ignore(),
                'last_modified_date' => ignore()}];
        cmp_deeply($actual, $expected, $test);

        $test = 'Going over landing company limits for iom triggers unwelcome status for the client';
        $sth_client_status->execute($Alice_id, 'unwelcome');
        $actual = $sth_client_status->fetchall_arrayref({});
        $expected->[0]{status_code} = 'unwelcome';
        cmp_deeply($actual, $expected, $test);
        $SQL = 'DELETE FROM betonmarkets.client_status WHERE client_loginid = ?';
        my $sth_clear_stats = $clientdbh->prepare($SQL);
        $sth_clear_stats->execute($Alice_id);

        $test = 'Transfer fails if amount exceeds client balance';
        modify_bom_config('payment_limits', 'withdrawal_limits/*/lifetime_limit = 100000');
        $testargs->{args}{amount} = $Alice_balance + $amount_boost;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{message_to_client}, "Sorry, you cannot withdraw. Your account balance is $test_currency $Alice_balance.", $test);
        $test_amount = $old_test_amount;
        reset_transfer_testargs();

        ## end of database function

        $test = 'Transfer fails when request is too frequent';
        ## First time works, second gets the error:
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Request too frequent/, $test);
        modify_bom_config('payment_limits', 'RESET');
        modify_bom_config('payment_agent',  'RESET');
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

    $test_amount = (grep { $_ eq $test_currency } @crypto_currencies) ? 0.003 : 101;
    $dry_run = 1;

    my $broker = 'CR';
    $Alice = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code    => $broker,
        binary_user_id => $bid++,
    });
    $Alice_id = $Alice->loginid;

    $Bob = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => $broker,

            binary_user_id => $bid++,
    });
    $Bob_id = $Bob->loginid;

    diag "Withdraw currency is $test_currency. Created Alice as $Alice_id and Bob as $Bob_id";

    reset_withdraw_testargs();

    subtest "paymentagent_withdraw $test_currency" => sub {

        $Alice->set_default_account($test_currency);
        $Bob->set_default_account($test_currency);
        $payment_agent_args->{currency_code} = $test_currency;
        $Bob->payment_agent($payment_agent_args);
        $Bob->save;

        $test = 'Withdraw fails if client has a virtual broker';
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{code}, 'PermissionDenied', $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if given an invalid amount';
        ## Cashier->_validate_amount declares that amounts must be: /^(?:\d+\.?\d*|\.\d+)$/
        for my $badamount (qw/ abc 1e80 1.2.3 1;2 . /) {
            $testargs->{args}{amount} = $badamount;
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            is($res->{error}{message_to_client}, 'Invalid amount.', "$test ($badamount)");
        }

        ## Precisions can be viewed via Format::Util::Numbers::get_precision_config();
        ## These checks rely on a local YAML file (e.g. 'precision.yml')
        for my $currency (@crypto_currencies, @fiat_currencies) {
            $testargs->{args}{currency} = $currency;
            my $precision = (grep { $_ eq $currency } @crypto_currencies) ? 8 : 2;
            $testargs->{args}{amount} = '1.2' . ('0' x $precision);
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
        $testargs->{client} = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent facilities are not available/, $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client cashier has a password';
        $Alice->cashier_setting_password('black');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your cashier is locked/, $test);
        $Alice->cashier_setting_password('');
        $Alice->save;

        $test                                   = 'Withdraw fails if both sides are the same account';
        $testargs->{args}{paymentagent_loginid} = $Alice_id;
        $res                                    = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'You cannot withdraw funds to the same account.', $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client has no residence';
        my $old_residence = $Alice->residence;
        $Alice->residence('');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/You cannot perform this action, please set your residence./, $test);
        $Alice->residence($old_residence);

        $test = q{Withdraw fails if payment agent facility not allowed in client's country};
        $Alice->residence('Walla Walla');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        $Alice->residence($old_residence);

        $test = 'Withdraw fails if client status = disabled';
        $Alice->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/account is currently disabled/, $test);
        $Alice->status->clear_disabled;
        $Alice->save;

        $test = 'Withdraw fails if payment agent does not exist';
        $mock_client_paymentagent->mock('new', sub { return ''; });
        $testargs->{args}{paymentagent_loginid} = 'NOSUCHUSER';
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, 'The payment agent account does not exist.', $test);
        $mock_client_paymentagent->unmock('new');
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client and payment agent have different brokers';
        ## Problem: Only CR currently allows payment agents, so we have to use a little trickery
        $Alice->broker('MLT');
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/withdrawals are not allowed for specified accounts/, $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $Alice->broker('CR');

        $test = 'Withdraw fails if client default account has wrong currency';
        my $alt_currency = first { $_ ne $test_currency } shuffle @fiat_currencies, @crypto_currencies;
        ## We have to mock because if set direct it is caught early by User::Client
        $mock_user_client->mock('currency', sub { return $alt_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/as $test_currency is not default currency for your account $Alice_id/, $test);
        $mock_user_client->unmock('currency');

        $test = 'Withdraw fails if payment agent default account has wrong currency';
        $mock_user_client->mock('currency', sub { return $_[0]->loginid eq $Bob_id ? $alt_currency : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/as $test_currency is not default currency for payment agent account $Bob_id/, $test);
        $mock_user_client->unmock('currency');

        $test = 'Transfer fails if amount is under the payment agent minimum';
        $testargs->{args}{amount} = (grep { $test_currency eq $_ } @crypto_currencies) ? 0.001 : 1.0;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is [\d\.]+, maximum is \d+/, $test);
        reset_withdraw_testargs();

        $test = 'Transfer fails if amount is over the payment agent maximum';
        $testargs->{args}{amount} = (grep { $test_currency eq $_ } @crypto_currencies) ? 10 : 10_000;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is [\d\.]+, maximum is \d+/, $test);
        reset_withdraw_testargs();

        $test = "Withdraw fails if description is over $MAX_DESCRIPTION_LENGTH characters";
        $testargs->{args}{description} = 'A' x (1 + $MAX_DESCRIPTION_LENGTH);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/instructions must not exceed $MAX_DESCRIPTION_LENGTH/, $test);
        reset_withdraw_testargs();

        $test = 'Withdraw fails if client status = cashier_locked';
        $Alice->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/your account is cashier locked/, $test);
        $Alice->status->clear_cashier_locked;
        $Alice->save;

        $test = 'Withdraw fails if client status = withdrawal_locked';
        $Alice->status->set('withdrawal_locked', 'Testy McTestington', 'Just running some tests');
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/your account is withdrawal locked/, $test);
        $Alice->status->clear_withdrawal_locked;
        $Alice->save;

        $Alice->place_of_birth('');
        $Alice->save;
        $test = 'Withdraw fails if missing place of birth';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your profile appears to be incomplete. Please update your personal details to continue./, $test);
        $Alice->place_of_birth('id');
        $Alice->save;

        $test = 'Withdraw fails if client authentication documents are expired';
        $auth_document_args->{expiration_date} = '1999-12-31';
        my ($doc) = $Alice->add_client_authentication_document($auth_document_args);
        $Alice->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/documents have expired/, $test);

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
        like($res->{error}{message_to_client}, qr/is marked as unwelcome/, $test);
        $Bob->status->clear_unwelcome;
        $Bob->save;

        $test = 'Withdraw fails if payment agent cashier has a password';
        $Bob->cashier_setting_password('white');
        $Bob->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/payment agent's cashier is locked/, $test);
        $Bob->cashier_setting_password('');
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
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/documents have expired/, $test);
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

        $test = 'Withdraw fails if client freeze attempt does not work';
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $Alice_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        ## Note that we use 'message', not 'message_to_client', due to specific strings
        like($res->{error}{message}, qr/stuck in previous transaction $Alice_id/, $test);
        $mock_clientdb->unmock('freeze');

        $test = 'Withdraw fails if payment agent freeze attempt does not work';
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $Bob_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message}, qr/stuck in previous transaction $Bob_id/, $test);
        $mock_clientdb->unmock('freeze');

        # mock to make sure that there is authenticated pa in Alice's country
        $mock_payment_agent->mock('get_authenticated_payment_agents', sub { return {pa1 => 'dummy'}; });
        $test          = q{You cannot withdraw from payment agent of different residence};
        $old_residence = $Alice->residence;
        $Alice->residence('in');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/You cannot withdraw from a payment agent in a different country of residence./, $test);
        $Alice->residence($old_residence);
        $mock_payment_agent->unmock('get_authenticated_payment_agents');

        $test = 'Withdrawal fails if payment agents are suspended in the target country';
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([$Alice->residence]);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{message_to_client}, "Payment agent transfers are temporarily unavailable in the client's country of residence.", $test);
        BOM::Config::Runtime->instance->app_config->system->suspend->payment_agents_in_countries([]);

        ## (validate_payment)

        $test = 'Withdrawal fails if amount exceeds client balance';
        my $Alice_balance = $Alice->default_account->balance;
        my $alt_amount    = $test_amount * 2;
        $testargs->{args}{amount} = $alt_amount;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        ## Cashier.pm does some remapping to Payments.pm
        like($res->{error}{message_to_client}, qr/Your account balance is $test_currency $Alice_balance/, $test);
        top_up $Alice, $test_currency => $MAX_DAILY_WITHDRAW_AMOUNT_WEEKDAY + 1;    ## Should work for all currencies

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
            like($res->{error}{message_to_client}, qr/transfer amount USD$show_amount for today/, $test);

            $test = 'Withdraw fails if amount requested is over withdrawal to date limit (weekend)';
            $testargs->{args}{amount} = $MAX_DAILY_WITHDRAW_AMOUNT_WEEKEND + 1;
            $mock_date_utility->mock('is_a_weekend', sub { return 1; });
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            $show_amount = formatnumber('amount', 'USD', $MAX_DAILY_WITHDRAW_AMOUNT_WEEKEND);
            like($res->{error}{message_to_client}, qr/transfer amount USD$show_amount for today/, $test);
            $agent_info->{payment_limits}{$currency_type}{maximum} = $old_max;
            $mock_date_utility->unmock('is_a_weekend');
            reset_withdraw_testargs();

        }

        ## We will assume this one is for all currencies, despite coming after the above:
        $test = "Withdraw fails if over maximum transactions per day ($MAX_DAILY_WITHDRAW_TXNS_WEEKDAY)";
        $mock_cashier->mock('_get_amount_and_count', sub { return 0, $MAX_DAILY_WITHDRAW_TXNS_WEEKDAY * 3; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/allowable transactions for today/, $test);
        $mock_cashier->unmock('_get_amount_and_count');

        # mock to make sure that there is authenticated pa in Alice's country
        $mock_payment_agent->mock('get_authenticated_payment_agents', sub { return {pa1 => 'dummy'}; });
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

        # to avoid request too frequent rest for 2 seconds
        sleep 2;

        $test = 'Withdraw returns correct paymentagent_name when dry_run is off';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{paymentagent_name}, $agent_name, $test);

        $test = 'Withdraw returns correct status of 1 when dry_run is off';
        is($res->{status}, 1, $test);

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

        ## Cleanup:
        $mock_utility->unmock('is_verification_token_valid');

    };

} ## end of each test_currency type

$mock_cashier->unmock('paymentagent_transfer');

done_testing();

sub modify_bom_config {

    ## In-place modification of the items returned by BOM::Config
    ## This is needed as mocking and clone/dclone do not work well, due to items declared as 'state'
    ## We assume all config items are "hashes all the way down"

    my $funcname = shift or die;

    BOM::Config->can($funcname) or die "Sorry, BOM::Config does not have a function named '$funcname'";

    my $config = BOM::Config->$funcname;
    ref $config eq 'HASH' or die "BOM::Config->$funcname is not a hash?!\n";

    if ($_[0] eq 'RESET') {
        walk_n_reset_bom_config($config);
        return;
    }

    sub walk_n_reset_bom_config {
        my $road = shift;
        return if !ref $road;
        for my $key (keys %$road) {
            walk_n_reset_bom_config($road->{$key}) if ref $road->{$key};
            if ($key =~ /^OLD_(.+)/) {
                $road->{$1} = delete $road->{$key};
            }
        }
    }

    for my $change (@_) {
        my ($path, $value) = $change =~ /(.+)\s+=\s+(.+)/
            or die "Format is path/to/change = value\n";
        my $locations = [$config];
        for my $current (split '/' => $path) {
            if ($current eq '*') {
                my $newlocations = [];
                for my $loc (@$locations) {
                    for my $key (keys %$loc) {
                        push @$newlocations => $loc->{$key};
                    }
                }
                $locations = $newlocations;
            } else {
                for my $loc (@$locations) {
                    if (!exists $loc->{$current}) {
                        die "BOM::Config->$funcname does not seem to have $current as part of $loc from path $path\n";
                    }
                    if (ref $loc->{$current}) {
                        $loc = $loc->{$current};
                    } else {
                        $loc->{"OLD_$current"} = $loc->{$current} if not exists $loc->{"OLD_$current"};
                        $loc->{$current} = $value;
                    }
                }
            }
        }
    }

    return;
}
