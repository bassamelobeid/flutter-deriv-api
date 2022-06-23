#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;

use Date::Utility;
use BOM::User::Client;
use BOM::Transaction;
use BOM::Transaction::Validation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Config::Runtime;

my $rose_client = BOM::User::Client->new({loginid => 'CR2002'});
my $loginid     = $rose_client->loginid;
my $account     = $rose_client->default_account;

use BOM::User;
use BOM::User::Password;

my $password = 'jskjd8292922';
my $email    = 'test' . rand(999) . '@binary.com';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

my $client;
lives_ok { $client = BOM::User::Client->new({loginid => $loginid}) } 'Can create client object.';

my $pa        = BOM::User::Client::PaymentAgent->new({loginid => 'CR0020'});
my $pa_client = $pa->client;

$user->add_client($client);

$client->payment_legacy_payment(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'ewallet',
);

my $sibling_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    date_joined        => '2000-01-02',
    myaffiliates_token => 'token1',
    residence          => 'id',
    binary_user_id     => $user->id,
});
$sibling_client->account('BTC');

subtest 'no doughflow payment for client - no flag set - payment agent withdrawal allowed' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    my $allow_withdraw = $client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, undef, 'no doughflow payment no flag set, allow payment agent withdrawal';
};

Test::Exception::lives_ok {
    $client->status->set('pa_withdrawal_explicitly_allowed', 'shuwnyuan', 'enable withdrawal through payment agent')
};
subtest 'no doughflow payment exists - withdrawal flag set - payment agent withdrawal allowed' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, undef, 'no doughflow payment exists,withdrawal allow flag set,so allow';
};

$client->payment_doughflow(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'external_cashier',
);
subtest 'doughflow payment exists for client - flag set - allow for payment agent withdrawal' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, undef, 'doughflow payment exist,flag set, allow for payment agent withdrawal';
};
Test::Exception::lives_ok { $client->status->clear_pa_withdrawal_explicitly_allowed };
subtest 'doughflow payment exists for client - no flag set - dont allow for payment agent withdrawal' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    my $allow_withdraw = $client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, 1, 'doughflow payment exist,no flag set, dont allow for payment agent withdrawal';
};

subtest 'doughflow payment exists for sibling - no flag set - dont allow for payment agent withdrawal' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    my $allow_withdraw = $sibling_client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, 1, 'doughflow payment exist,no flag set, dont allow for payment agent withdrawal';
};

my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';

my $validation_obj = BOM::Transaction::Validation->new({clients => [$client]});

#make sure unwelcome, disabled, no_trading, and no_withdrawal_or_trading client cannot trade
$client->status->set('unwelcome', $clerk, $reason);
ok(ref $validation_obj->_validate_client_status($client) eq 'Error::Base', "unwelcome client cannot trade");
$client->status->clear_unwelcome;

$client->status->set('disabled', $clerk, $reason);
ok(ref $validation_obj->_validate_client_status($client) eq 'Error::Base', "disabled client cannot trade");
$client->status->clear_disabled;

$client->status->set('no_trading', $clerk, $reason);
ok(ref $validation_obj->_validate_client_status($client) eq 'Error::Base', "no_trading client cannot trade");
$client->status->clear_no_trading;

$client->status->set('no_withdrawal_or_trading', $clerk, $reason);
ok(ref $validation_obj->_validate_client_status($client) eq 'Error::Base', "no_withdrawal_or_trading client cannot trade");
$client->status->clear_no_withdrawal_or_trading;

my $client_details = {
    broker_code              => 'MX',
    residence                => 'au',
    client_password          => 'x',
    last_name                => 'shuwnyuan',
    first_name               => 'tee',
    email                    => 'shuwnyuan@regentmarkets.com',
    salutation               => 'Ms',
    address_line_1           => 'ADDR 1',
    address_city             => 'Segamat',
    phone                    => '+60123456789',
    secret_question          => "Mother's maiden name",
    secret_answer            => 'blah',
    non_pep_declaration_time => time,
};

my %deposit = (
    currency     => 'USD',
    amount       => 1_000,
    remark       => 'here is money',
    payment_type => 'free_gift'
);

my $client_new = $user->create_client(%$client_details);
$validation_obj = BOM::Transaction::Validation->new({clients => [$client_new]});
$client_new->set_default_account('USD');

is($validation_obj->check_trade_status($client_new), undef, "MX client without age_verified allowed to trade before 1st deposit");
$client_new->payment_free_gift(%deposit);
ok(ref $validation_obj->check_trade_status($client_new) eq 'Error::Base', "MX client without age_verified cannot trade after 1st deposit");

$email = 'test1' . rand(999) . '@binary.com';
$user  = BOM::User->create(
    email    => $email,
    password => $hash_pwd
);

$client_details->{broker_code} = 'CR';

$client_new = $user->create_client(%$client_details);
$client_new->set_default_account('USD');

subtest 'no bank_wire payment for client - no flag set - payment agent withdrawal allowed' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    my $allow_withdraw = $client_new->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, undef, 'no bank_wire payment no flag set, allow payment agent withdrawal';
};

$client_new->payment_bank_wire(
    currency => 'USD',
    amount   => 1,
    remark   => 'here is money',
);

subtest 'bank_wire payment exists for client - no flag set - dont allow for payment agent withdrawal' => sub {
    BOM::Config::Runtime->instance->app_config->system->suspend->payment_agent_withdrawal_automation(1);
    my $allow_withdraw = $client->allow_paymentagent_withdrawal_legacy;
    is $allow_withdraw, 1, 'bank_wire payment exist,no flag set, dont allow for payment agent withdrawal';
};

done_testing();
