#!/usr/bin/perl
# -*- mode:cperl; indent-tabs-mode: nil; cperl-indent-level: 4; cperl-indent-parens-as-block: t; cperl-close-paren-offset: -4 -*-

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Data::Dumper;
use YAML::XS;

use Format::Util::Numbers qw( formatnumber );

use BOM::RPC::v3::Cashier;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Helper::Client qw( top_up );
use Email::Stuffer::TestLinks;

my ($agent, $payee, $payer, $test_currency, $test_amount, $testargs);

my @crypto_currencies = qw/ BCH BTC ETC ETH LTC /;
my @fiat_currencies   = qw/ AUD EUR GBP JPY USD /;

## Maximum characters allowed in a description field
my $long_description = 300;

my $agent_name = 'Joe';

my $WEEKEND_MAX               = BOM::Config::payment_agent()->{transaction_limits}->{withdraw}->{weekend}->{amount_in_usd_per_day};
my $WEEKDAY_MAX               = BOM::Config::payment_agent()->{transaction_limits}->{withdraw}->{weekday}->{amount_in_usd_per_day};
my $AGENT_TOPUP_AMOUNT_IN_USD = BOM::Config::payment_agent()->{transaction_limits}->{transfer}->{amount_in_usd_per_day};
my $MAX_TXNS_PER_DAY          = 20;

my %MAX_WITHDRAW = (
    USD => BOM::Config::payment_agent()->{payment_limits}->{fiat}->{maximum},
    BTC => BOM::Config::payment_agent()->{payment_limits}->{crypto}->{maximum});
my %MIN_AGENT_WITHDRAW = (
    USD => BOM::Config::payment_agent()->{payment_limits}->{fiat}->{minimum},
    BTC => BOM::Config::payment_agent()->{payment_limits}->{crypto}->{minimum});
my %MAX_AGENT_WITHDRAW = (
    USD => BOM::Config::payment_agent()->{payment_limits}->{fiat}->{maximum},
    BTC => BOM::Config::payment_agent()->{payment_limits}->{crypto}->{maximum});

## Create the accounts we will use for testing

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$client->set_default_account('USD');

my $crypto_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$crypto_client->set_default_account('BTC');

my $pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$pa_client->set_default_account('USD');

my $crypto_pa_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
$crypto_pa_client->set_default_account('BTC');

## Turn them into payment agents
my $payment_agent_args = {
    payment_agent_name    => $agent_name,
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
};

$pa_client->payment_agent($payment_agent_args);
$pa_client->save;

$payment_agent_args->{currency_code} = 'BTC';
$crypto_pa_client->payment_agent($payment_agent_args);
$crypto_pa_client->save;

my $mock_utility           = Test::MockModule->new('BOM::RPC::v3::Utility');
my $mock_clientaccount     = Test::MockModule->new('BOM::User::Client');
my $mock_landingcompany    = Test::MockModule->new('LandingCompany');
my $mock_clientdb          = Test::MockModule->new('BOM::Database::ClientDB');
my $mock_cashier           = Test::MockModule->new('BOM::RPC::v3::Cashier');
my $mock_date              = Test::MockModule->new('Date::Utility');
my $mock_currencyconverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mock_currencyconverter->mock('in_usd', sub { return $_[1] eq 'USD' ? $_[0] : 5000 * $_[0]; });

my $runtime_system = BOM::Config::Runtime->instance->app_config->system;

## Don't ever send an email out
$mock_clientaccount->mock('add_note', sub { return 1 });

my $res;

##
## Test of 'rpc paymentagent_transfer' in Cashier.pm
##

## Transfer money from a payment agent (souped-up Client) to a different Client

## paymentagent_transfer arguments:
## 'source': [string] appears unused, passed directly to payment_account_transfer
## 'client': [BOM::User::Client object] money FROM; the payment agent account
## 'website_name': [string] only used in outgoing confirmation email
## 'args' : [hashref] everything else below
##   'payment_transfer': [boolean] action to perform. NOT NEEDED?
##   'transfer_to': [loginid] money TO; raw string of the client loginid
##   'currency': [string]
##   'amount': [number]
##   'dry_run': [boolean]

sub reset_transfer_testargs {
    $testargs = {
        client => $agent,
        args   => {
            transfer_to => $payee->loginid,
            currency    => $test_currency,
            amount      => $test_amount,
            dry_run     => 1,
        }};
}

my $mock_cc         = Test::MockModule->new('ExchangeRates::CurrencyConverter');
my $mock_cashier_cc = Test::MockModule->new('BOM::RPC::v3::Cashier');
$mock_cc->mock('in_usd', sub { return $_[1] eq 'USD' ? $_[0] : 5000 * $_[0]; });
$mock_cashier_cc->mock('in_usd', sub { return $_[1] eq 'USD' ? $_[0] : 5000 * $_[0]; });

for my $transfer_currency ('USD', 'BTC') {

    $test_currency = $transfer_currency;

    subtest "paymentagent_transfer $test_currency" => sub {

        if ('USD' eq $test_currency) {
            ## To reduce confusion, we will call the {client} payment agent just $agent
            $agent = $pa_client;
            ## The transfer_to client will be $payee
            $payee       = $client;
            $test_amount = 100;
        } elsif ('BTC' eq $test_currency) {
            $agent       = $crypto_pa_client;
            $payee       = $crypto_client;
            $test_amount = 0.004;
        }

        reset_transfer_testargs();

        my $agent_id = $agent->loginid;
        my $payee_id = $payee->loginid;

        my $test = 'Transfer fails if payment agent has virtual broker';
        my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $testargs->{client} = $vr_client;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{error}{code}, 'PermissionDenied', $test);
        reset_transfer_testargs();

        $test = 'Transfer fails if given an invalid amount';
        ## Cashier.pm declares that amounts must be: /^(?:\d+\.?\d*|\.\d+)$/
        for my $badamount (qw/ abc 1e80 1.2.3 1;2 . /) {
            $testargs->{args}{amount} = $badamount;
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            is($res->{error}{message_to_client}, 'Invalid amount.', "$test ($badamount)");
        }
        ## Precisions can be viewed via Format::Util::Numbers::get_precision_config();
        for my $currency (@crypto_currencies, @fiat_currencies) {
            $testargs->{args}{currency} = $currency;
            my $precision = (grep { $_ eq $currency } @crypto_currencies) ? 8 : 2;
            $testargs->{args}{amount} = '1.2' . ('0' x $precision);
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            like(
                $res->{error}{message_to_client},
                qr/Invalid amount.* $precision decimal places/,
                "$test ($currency must be <= $precision decimal places)"
            );
        }
        reset_transfer_testargs();

        $test = 'Transfer error gives expected code';
        ## Quick check at least this one time
        my $error_code = 'PaymentAgentTransferError';
        is($res->{error}{code}, $error_code, "$test ($error_code)");

        ## Note: all of these tests come before the "too frequent" check
        ## So if they start unexpectedly failing to fail as they ought to,
        ## you will probably see a frequency error

        $test = 'Transfer fails if payments are suspended';
        $runtime_system->suspend->payments(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payments(0);

        $test = 'Transfer fails if payment agents are suspended';
        $runtime_system->suspend->payment_agents(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payment_agents(0);

        $test = 'Transfer fails if system is suspended';
        $runtime_system->suspend->system(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->system(0);

        $test = 'Transfer fails if payment agent facility not available/';
        ## Right now only CR offers payment agents according to:
        ## /home/git/regentmarkets/cpan/local/lib/perl5/auto/share/dist/LandingCompany/landing_companies.yml
        my $malta_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
        $testargs->{client} = $malta_client;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        ## Subtle wording difference from the same error in paymentagent_withdraw!
        like($res->{error}{message_to_client}, qr/agent facility is not available/, $test);
        reset_transfer_testargs();

        $test = 'Transfer fails if client has no associated payment_agent';
        ## Switch to a client that has no payment_agent set
        $testargs->{client} = $payee;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/not authorized for transfers via payment agents/, $test);
        reset_transfer_testargs();

        $test                                     = 'Transfer fails if payment agent is not authenticated';
        $agent->{payment_agent}{is_authenticated} = 0;
        $res                                      = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/needs to be authenticated/, $test);
        $agent->{payment_agent}{is_authenticated} = 1;

        $test = 'Transfer fails if payment agent cashier is locked';
        $agent->cashier_setting_password('fortytwo');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Your cashier is locked/, $test);
        $agent->cashier_setting_password('');

        $test = 'Transfer fails if currency does match default for the payment agent account';
        $mock_clientaccount->mock('currency', sub { return $_[0]->loginid eq $agent_id ? 'XYZ' : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/$test_currency is not the default account currency for payment agent/, $test);
        $mock_clientaccount->unmock('currency');

        $test = 'Transfer fails if payment agent does not have a default account';
        $mock_clientaccount->mock('default_account', sub { return 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/$test_currency is not the default account currency for payment agent/, $test);
        $mock_clientaccount->unmock('default_account');

        $test                          = 'Transfer fails if the "transfer_to" client (aka payee) cannot be found';
        $testargs->{args}{transfer_to} = q{Invalid O'Hare};
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Login ID .+ does not exist/, $test);
        reset_transfer_testargs();

        $test = 'Transfer fails if currency does match default for the payee account';
        $mock_clientaccount->mock('currency', sub { return $_[0]->loginid eq $payee_id ? 'XYZ' : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/$test_currency is not the default account currency for client/, $test);
        $mock_clientaccount->unmock('currency');

        $test = 'Transfer fails if payee does not have a default account';
        ## We must return the actual BOM::Database::AutoGenerated::Rose::Account object so the first check passes!
        my $defaultaccount = $agent->default_account;
        $mock_clientaccount->mock('default_account', sub { return $_[0]->loginid eq $agent_id ? $defaultaccount : 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/$test_currency is not the default account currency for client/, $test);
        $mock_clientaccount->unmock('default_account');

        $test = 'Transfer fails if amount is over the payment agent maximum';
        my $max = $test_currency eq 'USD' ? 3 : 0.003;
        $agent->payment_agent->max_withdrawal($max);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Maximum withdrawal allowed is $max\./, $test);
        $agent->payment_agent->max_withdrawal(undef);

        $test = 'Transfer fails if amount is under the payment agent minimum';
        $agent->payment_agent->min_withdrawal(333);
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum withdrawal allowed is 3./, $test);
        $agent->payment_agent->min_withdrawal(undef);

        $test = 'Transfer fails is amount is over the landing company maximum';
        my $currency_type = LandingCompany::Registry::get_currency_type($test_currency);      ## e.g. "fiat"
        my $lim           = BOM::Config::payment_agent()->{payment_limits}{$currency_type};
        $max                      = $lim->{maximum};
        $testargs->{args}{amount} = $max * 1.5;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Maximum is $max./, "$test ($max for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails is amount is over the landing company maximum';
        my $min = $lim->{minimum};
        $testargs->{args}{amount} = $min * 0.5;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is $min./, "$test ($min for $currency_type)");
        reset_transfer_testargs();

        $test = 'Transfer fails if payment agent account is disabled';
        $agent->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/your account is currently disabled/, $test);
        $agent->status->clear('disabled');

        $test = 'Transfer fails if payment agent account is cashier locked';
        $agent->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/your account is cashier locked/, $test);
        $agent->status->clear('cashier_locked');

        $test = 'Transfer fails if payment agent documents have expired';
        $mock_clientaccount->mock('documents_expired', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/documents have expired/, $test);
        $mock_clientaccount->unmock('documents_expired');

        $test = 'Transfer fails if payment agent and payee have different landing companies';
        ## First we force the agent to use Malta as their landing company:
        $mock_clientaccount->mock(
            'landing_company',
            sub {
                return LandingCompany::Registry->get_by_broker($_[0]->loginid eq $agent_id ? 'MLT' : 'CR');
            });
        ## Then we need to declare that Malta can have payment agents too
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        ## Note: this has a very odd error message
        like($res->{error}{message_to_client}, qr/Payment agent transfers are not allowed/, $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $mock_clientaccount->unmock('landing_company');

        $test                          = 'Transfer fails if payment agent and payee are the same account';
        $testargs->{args}{transfer_to} = $agent_id;
        $res                           = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/transfers are not allowed within the same account/, $test);
        reset_transfer_testargs();

        $test = 'Transfer fails if payee account is disabled';
        $payee->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/their account is currently disabled/, $test);
        $payee->status->clear('disabled');

        $test = 'Transfer fails if payee account is unwelcome';
        $payee->status->set('unwelcome', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/their account is marked as unwelcome/, $test);
        $payee->status->clear('unwelcome');

        $test = 'Transfer fails if payee account is cashier locked';
        $payee->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/their cashier is locked/, $test);
        $payee->status->clear('cashier_locked');

        $test = 'Transfer fails if payee account has a cashier password set';
        $payee->cashier_setting_password('bob');
        $payee->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/their cashier is locked/, $test);
        $payee->cashier_setting_password(undef);
        $payee->save;

        $test = 'Transfer fails if payee account documents are expired';
        $mock_clientaccount->mock('documents_expired', sub { return $_[0]->loginid eq $payee_id ? 1 : 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/their verification documents have expired/, $test);
        $mock_clientaccount->unmock('documents_expired');

        $test = 'Transfer works and returns a status of 2 when dry_run is set';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 2, $test);

        $test = 'Transfer works and returns correct payee full name when dry_run is set';
        is($res->{client_to_full_name}, $payee->full_name, $test);
        $test = 'Transfer works and returns correct payee loginid when dry_run is set';
        is($res->{client_to_loginid}, $payee_id, $test);

        $test = 'Transfer fails if payee freeze attempt does not work';
        ## No need to reset this: leave it off until the end
        $testargs->{args}{dry_run} = 0;
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $payee_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        ## Note that we use 'message', not 'message_to_client', due to nicely specific strings
        like($res->{error}{message}, qr/stuck in previous transaction $payee_id/, $test);
        $mock_clientdb->unmock('freeze');

        $test = 'Transfer fails if agent freeze attempt does not work';
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $agent_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message}, qr/stuck in previous transaction $agent_id/, $test);
        $mock_clientdb->unmock('freeze');

        ## Checking validate_payment(), but errors come from __client_withdrawal_notes()
        $test = 'Transfer fails if agent has insufficient funds';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/you cannot withdraw.+balance is $test_currency 0.00/, $test);

        $test = 'Agent account starts with a zero balance';

        my $agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
        is($agent_balance, 0, $test);

        $test = 'Payee account starts with a predetermined balance';
        my $test_seed = 'USD' eq $test_currency ? 500 : 1;
        top_up $payee, $test_currency, $test_seed;
        my $payee_balance = BOM::User::Client->new({loginid => $payee_id})->default_account->balance;
        is($payee_balance, formatnumber('amount', $test_currency, $test_seed), $test);

        $test = 'After top_up, agent account has correct balance';
        my $agent_funds = 400;
        top_up $agent, $test_currency => $agent_funds;
        $agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
        is($agent_balance, formatnumber('amount', $test_currency, $agent_funds), $test);

        $test = 'Transfer works and returns a status code of 1';
        $res  = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        is($res->{status}, 1, $test);

        $test = 'After transfer, agent account has correct balance';
        $agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
        is($agent_balance, formatnumber('amount', $test_currency, $agent_funds - $test_amount), $test);

        $test = 'After transfer, payee account has correct balance';
        $payee_balance = BOM::User::Client->new({loginid => $payee_id})->default_account->balance;
        is($payee_balance, formatnumber('amount', $test_currency, $test_seed + $test_amount), $test);

        $test                     = 'Transfer fails when request is too frequent';
        $testargs->{args}{amount} = $test_amount;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/Request too frequent/, $test);

        $test = 'Transfer fails if frozen_free_gift is in effect';
        $mock_clientaccount->mock('get_promocode_dependent_limit', sub { return {frozen_free_gift => 500} });
        $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
        like($res->{error}{message_to_client}, qr/includes frozen bonus/, $test);
        $mock_clientaccount->unmock('get_promocode_dependent_limit');

        subtest "paymentagent_transfer allowance $test_currency" => sub {

            reset_transfer_testargs();

            my $value_per_usd = ExchangeRates::CurrencyConverter::in_usd(1, $test_currency);

            # test withdrawl amount in usd
            my $test_wd_amt_in_usd = 1000;

            # payment agent
            my $pa = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/paymentagent_config.yml');

            # transaction limit amount per day
            my $tl_amt_per_day = $pa->{transaction_limits}->{transfer}->{amount_in_usd_per_day} / $value_per_usd;
            $pa->{payment_limits}->{fiat}->{maximum}   = $tl_amt_per_day;
            $pa->{payment_limits}->{crypto}->{maximum} = $tl_amt_per_day;

            # set the payment limit per transaction to the max allowable transfer in a day
            my $pl = YAML::XS::LoadFile('/home/git/regentmarkets/bom-config/share/payment_limits.yml');
            # costarica and champion both are in the currency of USD, so no conversion is needed
            $pl->{withdrawal_limits}->{costarica}->{lifetime_limit} =
                $pa->{transaction_limits}->{transfer}->{amount_in_usd_per_day} + $test_wd_amt_in_usd;
            $pl->{withdrawal_limits}->{champion}->{lifetime_limit} =
                $pa->{transaction_limits}->{transfer}->{amount_in_usd_per_day} + $test_wd_amt_in_usd;

            my $mock_config = Test::MockModule->new('BOM::Config');
            $mock_config->mock('payment_agent',  sub { return $pa; });
            $mock_config->mock('payment_limits', sub { return $pl; });

            # make sure topup amount is worth the same in different currencies
            my $topup_amount = $AGENT_TOPUP_AMOUNT_IN_USD / $value_per_usd;

            # get the previously transferred amount by other test cases
            my ($prev_transfer_amt, $prev_transfer_cnt) = BOM::RPC::v3::Cashier::_get_amount_and_count($agent_id);

            # amount to be transferred to the payee to hit the transfer limit
            $test_amount = $topup_amount - $prev_transfer_amt;

            # store previous agent and client balance before top up
            my $prev_agent_balance  = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
            my $prev_client_balance = BOM::User::Client->new({loginid => $payee_id})->default_account->balance;

            # topup agent
            top_up $agent, $test_currency, $topup_amount;

            ## run payment transfer tests
            # transfer the money from agent to payee until it reaches the maximum it can deposit
            $test = "Amount: $test_amount has been successful transferred to the client";
            $testargs->{args}{dry_run} = 0;
            # set the amount to be transferred for each iteration
            $testargs->{args}->{amount}   = $test_amount;
            $testargs->{args}->{currency} = $test_currency;

            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            my ($amt, $tmp) = BOM::RPC::v3::Cashier::_get_amount_and_count($agent_id);
            is($res->{status}, 1, $test);

            # make sure that the amount before the transfer and after the transfer matches
            $test = "Transfer amount in usd per day matches the maximum transaction limit";
            my ($transfer_amt, $transfer_cnt) = BOM::RPC::v3::Cashier::_get_amount_and_count($agent_id);
            is($transfer_amt, $tl_amt_per_day, $test);

            # make sure right amount has been deducted from agent
            $test = 'After transfer, agent account has correct balance';
            $agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
            # the agent balance should be maximum amount allowable after the test
            is($agent_balance, formatnumber('amount', $test_currency, $prev_agent_balance + $prev_transfer_amt), $test);

            # make sure right amount has been deposited to the payee
            $test = 'After transfer, payee account has correct balance';
            $payee_balance = BOM::User::Client->new({loginid => $payee_id})->default_account->balance;
            is($payee_balance, formatnumber('amount', $test_currency, $prev_client_balance + $test_amount), $test);

            # testcase for transferring to another client should be disabled, as the agent hits the maximum transfer amount
            top_up $agent, $test_currency, $topup_amount;
            # set the amount to be transferred for each iteration
            $testargs->{args}->{amount} = $test_wd_amt_in_usd / $value_per_usd;
            $res = BOM::RPC::v3::Cashier::paymentagent_transfer($testargs);
            like($res->{error}{message_to_client}, qr/exceeded the maximum allowable transfer amount for today/, $test);

            # unmock
            $mock_config->unmock('payment_agent');
            $mock_config->unmock('payment_limits');

            # reset client back to its previous balance
            if ($test_currency eq 'USD') {
                $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
                $client->set_default_account('USD');
                top_up $client, $test_currency, $prev_client_balance;
            } elsif ($test_currency eq 'BTC') {
                $crypto_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'CR'});
                $crypto_client->set_default_account('BTC');
                top_up $crypto_client, $test_currency, $prev_client_balance;
            }

        };

        $test = 'Transfer fails if we go above the lifetime limit for the client';
        ## Hard to mock: limits are pulled from external file by Payments.pm

    };

} ## end each type of currency for paymentagent_transfer

##
## Test of 'rpc paymentagent_withdraw' in Cashier.pm
##

## Withdraw money from a Client to a souped-up Client (with a payment agent)
## Pretty much the reverse of the transfer above?

## paymentagent_withdraw arguments:
## 'source': [string] appears unused, passed directly to payment_account_transfer
## 'client': [CLinet::Account object] money FROM; a normal, non payment-agent account
## 'args' : [hashref] everything else below
##   'payment_withdraw': [boolean] action to perform. NOT NEEDED?
##   'paymentagent_loginid': [string] money TO; the payment agent account
##   'currency': [string]
##   'amount': [number]
##   'verification_code': [string]
##   'dry_run': [boolean]

sub reset_withdrawal_testargs {
    $testargs = {
        client => $payer,
        args   => {
            paymentagent_loginid => $agent->loginid,
            currency             => $test_currency,
            amount               => $test_amount,
            verification_code    => 'dummy',
            dry_run              => 1,
        }};
}

for my $withdraw_currency ('USD', 'BTC') {

    $test_currency = $withdraw_currency;

    subtest "paymentagent_withdraw $test_currency" => sub {

        if ('USD' eq $test_currency) {
            ## To reduce confusion, we will call the {paymentagent_loginid} payment agent just $agent
            $agent = $pa_client;
            ## The transfer_to client will be $payee
            $payer       = $client;
            $test_amount = 100;
        } elsif ('BTC' eq $test_currency) {
            $agent       = $crypto_pa_client;
            $payer       = $crypto_client;
            $test_amount = 0.004;
        }

        reset_withdrawal_testargs();

        my $agent_id = $agent->loginid;
        my $payer_id = $payer->loginid;

        ## Reset mocked subroutines as needed
        $mock_utility->unmock('is_verification_token_valid')
            if $mock_utility->is_mocked('is_verification_token_valid');

        my $test = 'Withdrawal fails if payer has virtual broker';
        my $vr_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'VRTC'});
        $testargs->{client} = $vr_client;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{code}, 'PermissionDenied', $test);
        reset_withdrawal_testargs();

        $test                                   = 'Withdrawal fails if payer has same logind as payment agent one';
        $testargs->{args}{paymentagent_loginid} = $payer->loginid;
        $res                                    = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{error}{code}, 'PaymentAgentWithdrawError', $test);
        reset_withdrawal_testargs();

        $test = 'Withdrawal works if token is not valid and dry_run is enabled';
        $res  = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        ## The dry_run argument always gives a status of 2 (not 1) and returns early
        is($res->{status}, 2, $test) or diag Dumper $res;

        $test                      = 'Withdrawal fails if token is not valid and dry_run is disabled';
        $testargs->{args}{dry_run} = 0;
        $res                       = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/token.+invalid/, $test);

        ## Cannot assume we start at zero because of the previous tests
        $test = 'Withdrawal works and returns a status code of 1';
        my $old_payer_balance = BOM::User::Client->new({loginid => $payer_id})->default_account->balance;
        my $old_agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
        ## Ensure that all tokens are now 'valid'
        $mock_utility->mock('is_verification_token_valid', sub { return {status => 1} });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        is($res->{status}, 1, $test);

        $test = 'After transfer, payer account has correct balance';
        my $payer_balance = BOM::User::Client->new({loginid => $payer_id})->default_account->balance;
        is($payer_balance, formatnumber('amount', $test_currency, $old_payer_balance - $test_amount), $test);

        $test = 'After transfer, agent account has correct balance';
        my $agent_balance = BOM::User::Client->new({loginid => $agent_id})->default_account->balance;
        is($agent_balance, formatnumber('amount', $test_currency, $old_agent_balance + $test_amount), $test);

        $test = 'After withdrawal, correct agent name is returned';
        is($res->{paymentagent_name}, $agent_name, $test);

        $test = 'Withdrawal fails if given an invalid amount';
        ## Cashier.pm declares that amounts must be: /^(?:\d+\.?\d*|\.\d+)$/
        for my $badamount (qw/ abc 1e80 1.2.3 1;2 . /) {
            $testargs->{args}{amount} = $badamount;
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            is($res->{error}{message_to_client}, 'Invalid amount.', "$test ($badamount)");
        }
        ## Precisions can be viewed via Format::Util::Numbers::get_precision_config();
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
        $testargs->{args}{currency} = $test_currency;
        $testargs->{args}{amount}   = $test_amount;

        $test = 'Withdraw error gives expected code';
        ## Quick check at least this one time
        my $error_code = 'PaymentAgentWithdrawError';
        is($res->{error}{code}, $error_code, "$test ($error_code)");

        ## Note: all of these tests come before the "too frequent" check
        ## So if they start unexpectedly failing to fail as they ought to,
        ## you will probably see a frequency error

        $test = 'Withdrawal fails if payments are suspended';
        my $runtime_system = BOM::Config::Runtime->instance->app_config->system;
        $runtime_system->suspend->payments(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payments(0);

        $test = 'Withdrawal fails if payment_agents are suspended';
        $runtime_system->suspend->payment_agents(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->payment_agents(0);

        $test = 'Withdrawal fails if system is suspended';
        $runtime_system->suspend->system(1);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/due to system maintenance/, $test);
        $runtime_system->suspend->system(0);

        $test = 'Withdrawal fails if T&C approval is needed';
        ## Right now CR clients don't require T&C acceptance
        my $malta_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({broker_code => 'MLT'});
        $testargs->{oldclient} = $testargs->{client};
        $testargs->{client}    = $malta_client;
        $res                   = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Terms and conditions approval is required/, $test);
        $malta_client->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);

        $test = 'Withdrawal fails if payment agent facility not available/';
        ## Right now only CR offers payment agents according to:
        ## /home/git/regentmarkets/cpan/local/lib/perl5/auto/share/dist/LandingCompany/landing_companies.yml
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent facilities are not available/, $test);
        $testargs->{client} = delete $testargs->{oldclient};

        $test = 'Withdrawal fails if payment agent withdrawal not allowed';
        $payer->payment_agent_withdrawal_expiration_date('2017-01-01');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/not authorized for withdrawals via payment agents/, $test);
        $payer->payment_agent_withdrawal_expiration_date('2999-01-01');

        $test = 'Withdrawal fails if client cashier is locked';
        $payer->cashier_setting_password('fortytwo');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Your cashier is locked/, $test);
        $payer->cashier_setting_password('');

        $test = 'Withdrawal fails if payment agent not available in country of client';
        my $oldresidence = $payer->residence;
        $payer->residence('WallaWalla');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/not available in your country/, $test);
        $payer->residence($oldresidence);

        $test = 'Withdrawal fails if client account is disabled';
        $payer->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/account is currently disabled/, $test);
        $payer->status->clear('disabled');

        $test = 'Withdrawal fails if the payment agent does not exist';
        $testargs->{args}{paymentagent_loginid} .= '12345';
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent account does not exist/, $test);
        $testargs->{args}{paymentagent_loginid} = $agent_id;

        $test = 'Withdrawal fails if client and payment agent have different brokers';
        ## Problem: Only CR currently allows payment agents, so we have to use a little trickery
        $payer->broker('MLT');
        $payer->status->set('tnc_approval', 'system', BOM::Config::Runtime->instance->app_config->cgi->terms_conditions_version);
        $payer->save;
        $mock_landingcompany->mock('allows_payment_agents', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/withdrawals are not allowed for specified accounts/, $test);
        $mock_landingcompany->unmock('allows_payment_agents');
        $payer->broker('CR');

        $test                       = 'Withdrawal fails if currency does match default for the client account';
        $testargs->{args}{currency} = 'GBP';
        $testargs->{args}{amount}   = 10;                                                                         ## Something suitable for GBP
        $res                        = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/not default currency for your account/, $test);
        $testargs->{args}{currency} = $test_currency;
        $testargs->{args}{amount}   = $test_amount;

        $test = 'Withdrawal fails if client has no default account';
        $mock_clientaccount->mock('default_account', sub { return 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        ## Same error message as above, sadly
        like($res->{error}{message_to_client}, qr/not default currency for your account/, $test);
        $mock_clientaccount->unmock('default_account');

        $test = 'Withdrawal fails if currency does match default for the payment agent account';
        ## Trickier, as Cashier.pm creates a new client object for the pa based only on loginid
        $mock_clientaccount->mock('currency', sub { return $_[0]->loginid eq $agent_id ? 'XYZ' : $test_currency; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/not default currency for payment agent account/, $test);
        $mock_clientaccount->unmock('currency');

        $test = 'Withdrawal fails if payment agent has no default account';
        ## Here, we must return the actual BOM::Database::AutoGenerated::Rose::Account object so the first check passes
        my $defaultaccount = $payer->default_account;
        $mock_clientaccount->mock('default_account', sub { return $_[0]->loginid eq $payer_id ? $defaultaccount : 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/not default currency for payment agent account/, $test);
        $mock_clientaccount->unmock('default_account');

        $test = "Withdrawal fails if amount is below minimum for current currency ($test_currency)";
        my ($min, $max) = ($MIN_AGENT_WITHDRAW{$test_currency}, $MAX_AGENT_WITHDRAW{$test_currency});
        $testargs->{args}{amount} = $min * 0.99;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is $min, maximum is $max/, $test);

        $test                     = "Withdrawal fails if amount is above maximum for current currency ($test_currency)";
        $testargs->{args}{amount} = $max * 1.01;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Invalid amount. Minimum is $min, maximum is $max/, $test);
        $testargs->{args}{amount} = $test_amount;

        $test = "Withdrawal fails if description is over $long_description characters";
        $testargs->{args}{description} = 'A' x (1 + $long_description);
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/instructions must not exceed $long_description/, $test);
        $testargs->{args}{description} = 'good';

        $test = 'Withdrawal fails if client account is cashier locked';
        $payer->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/your account is cashier locked/, $test);
        $payer->status->clear('cashier_locked');

        $test = 'Withdrawal fails if client account is withdrawal locked';
        $payer->status->set('withdrawal_locked', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/your account is withdrawal locked/, $test);
        $payer->status->clear('withdrawal_locked');

        $test = 'Withdrawal fails if client documents have expired';
        $mock_clientaccount->mock('documents_expired', sub { return 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/documents have expired/, $test);
        $mock_clientaccount->unmock('documents_expired');

        $test = 'Withdrawal fails if payment agent account is disabled';
        $agent->status->set('disabled', 'Testy McTestington', 'Just running some tests');
        ## We need 'save' here because Cashier uses the pa_loginid to generate a fresh client account object
        $agent->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent's account is disabled/, $test);
        $agent->status->clear('disabled');

        $test = 'Withdrawal fails if payment agent account is marked as unwelcome';
        $agent->status->set('unwelcome', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent's account is marked as unwelcome/, $test);
        $agent->status->clear('unwelcome');

        $test = 'Withdrawal fails if payment agent account is cashier locked';
        $agent->status->set('cashier_locked', 'Testy McTestington', 'Just running some tests');
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent's cashier is locked/, $test);
        $agent->status->clear('cashier_locked');

        $test = 'Withdrawal fails if payment agent account has cashier password';
        $agent->cashier_setting_password('alice');
        $agent->save;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent's cashier is locked/, $test);
        $agent->cashier_setting_password(undef);
        $agent->save;

        $test = 'Withdrawal fails if payment agent documents have expired';
        $mock_clientaccount->mock('documents_expired', sub { $_[0]->loginid eq $agent_id ? 1 : 0; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/agent's verification documents have expired/, $test);
        $mock_clientaccount->unmock('documents_expired');

        $test = 'Withdrawal fails if client freeze attempt does not work';
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $payer_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        ## Note that we use 'message', not 'message_to_client', due to specific strings
        like($res->{error}{message}, qr/stuck in previous transaction $payer_id/, $test);
        $mock_clientdb->unmock('freeze');

        $test = 'Withdrawal fails if agent freeze attempt does not work';
        $mock_clientdb->mock('freeze', sub { $_[0]->loginid eq $agent_id ? 0 : 1; });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message}, qr/stuck in previous transaction $agent_id/, $test);
        $mock_clientdb->unmock('freeze');

        ## Withdrawal fails if amount is above maximum for current
        ## Checking validate_payment(), but errors come from __client_withdrawal_notes()
        $test                     = 'Withdrawal fails if client has insufficient funds';
        $testargs->{args}{amount} = $MAX_WITHDRAW{$test_currency} * 0.99;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        my $fancyamount = formatnumber('amount', $test_currency, $payer_balance);
        like($res->{error}{message_to_client}, qr/you cannot withdraw.+balance is $test_currency $payer_balance/, $test);

        $test                     = 'Withdrawal fails when request is too frequent';
        $testargs->{args}{amount} = $test_amount;
        $res                      = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/Request too frequent/, $test);

        ## We are testing Client/Payments::validate_payment, but not completely, as many
        ## of its early checks are duplicated (e.g. "fail if cashier is locked")

        $test = 'Withdrawal fails if frozen_free_gift is in effect';
        $mock_clientaccount->mock('get_promocode_dependent_limit', sub { return {frozen_free_gift => 500} });
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/includes frozen bonus/, $test);
        $mock_clientaccount->unmock('get_promocode_dependent_limit');

        $test = 'Withdrawal fails if amount requested is over withdrawal to date limit';
        ## This is very hard to mock, so we are going to do multiple withdrawals until we hit this limit

        ## Complication 1: test client does not have enough money to hit the limit
        ## Solution: give them a lot of money via the top_up function
        top_up $client, $test_currency => 8675;    ## Ok for USD, crazy for BTC!

        ## Complication 2: hard-coded daily limits in Cashier.pm, which depend on weekday vs weekend
        ## Solution: force Date::Utility to think it is January 1, 2018, a Monday - or 20180106, a Saturday
        $mock_date->mock('is_a_weekend', sub { return 1 });

        ## Complication 3: withdrawals happening too often trigger a frequency error
        ## Solution: add a sleep and warn the tester via diag

        ## Complication 4: lots of hard-coded numbers and assumptions
        ## Solution: tweak these values when the tests start breaking :)

        ## These limits only make sense for USD, although all currencies are checked?!?
        if ($test_currency eq 'USD') {

            ## Balance should be 9075. Going to withdraw max which should trigger weekend limit
            $testargs->{args}{amount} = $MAX_WITHDRAW{$test_currency};
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            like($res->{error}{message_to_client}, qr/transfer amount USD$WEEKEND_MAX.00 for today/, "$test (weekend)");

            ## For weekday, we need two more withdrawals in a row
            $mock_date->mock('is_a_weekend', sub { return 0 });
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            diag 'Sleeping for 2 seconds to get around the frequency check';
            sleep 2;
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            diag 'Sleeping for 2 seconds to get around the frequency check';
            sleep 2;
            $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
            like($res->{error}{message_to_client}, qr/transfer amount USD$WEEKDAY_MAX.00 for today/, "$test (weekday)");
        }

        $test = "Withdrawal fails if over maximum transactions per day ($MAX_TXNS_PER_DAY)";
        $mock_cashier->mock('_get_amount_and_count', sub { return 0, $MAX_TXNS_PER_DAY * 3; });
        diag 'Sleeping for 2 seconds to get around the frequency check';
        sleep 2;
        $res = BOM::RPC::v3::Cashier::paymentagent_withdraw($testargs);
        like($res->{error}{message_to_client}, qr/allowable transactions for today/, $test);
        $mock_cashier->unmock('_get_amount_and_count');

    };

} ## end of each test_currency type

$mock_cc->unmock('in_usd');
$mock_cashier_cc->unmock('in_usd');

done_testing();
