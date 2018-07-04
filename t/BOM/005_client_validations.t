#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;

use Date::Utility;
use BOM::User::Client;
use BOM::Transaction::Validation;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

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

$client->payment_legacy_payment(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'ewallet',
);
my $validation_obj = BOM::Transaction::Validation->new({clients => [$client]});

subtest 'no doughflow payment for client - allow for payment agent withdrawal' => sub {
    my $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client);
    is $allow_withdraw, 1, 'no doughflow payment no expiry date set, allow payment agent withdrawal';
};

my $expire_date_before = Date::Utility->new(time() - 86400)->date_yyyymmdd;
$client->payment_agent_withdrawal_expiration_date($expire_date_before);
subtest 'no doughflow payment exists, expiration date exists in past ' => sub {
    my $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client);
    is $allow_withdraw, undef, 'no doughflow payment exists but expiration date so dont allow';
};

$client->payment_doughflow(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'external_cashier',
);

subtest 'doughflow payment exists for client - not allow for payment agent withdrawal' => sub {
    my $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client);
    is $allow_withdraw, undef, 'doughflow payment exist, not allow for payment agent withdrawal';
};

$expire_date_before = Date::Utility->new(time() - 86400)->date_yyyymmdd;
$client->payment_agent_withdrawal_expiration_date($expire_date_before);
subtest 'doughflow payment exists for client - with past payment_agent_withdrawal_expiration_date' => sub {
    my $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client);
    is $allow_withdraw, undef, 'with past payment_agent_withdrawal_expiration_date';
};

my $expire_date_after = Date::Utility->new(time() + 86400)->date_yyyymmdd;
$client->payment_agent_withdrawal_expiration_date($expire_date_after);
subtest 'doughflow payment exists for client - with future dated payment_agent_withdrawal_expiration_date' => sub {
    my $allow_withdraw = $validation_obj->allow_paymentagent_withdrawal($client);
    is $allow_withdraw, 1, 'with future dated payment_agent_withdrawal_expiration_date';
};

my $reason = "test to set unwelcome login";
my $clerk  = 'shuwnyuan';

# lock client cashier
Test::Exception::lives_ok { $client->set_status('unwelcome', $clerk, $reason) } "set client unwelcome login";

# save changes to CR.lockcashierlogins
Test::Exception::lives_ok { $client->save() } "can save to unwelcome login file";

#make sure unwelcome client cannot trade
ok(ref $validation_obj->_validate_client_status($client) eq 'Error::Base', "unwelcome client cannot trade");

my $client_details = {
    broker_code     => 'MX',
    residence       => 'au',
    client_password => 'x',
    last_name       => 'shuwnyuan',
    first_name      => 'tee',
    email           => 'shuwnyuan@regentmarkets.com',
    salutation      => 'Ms',
    address_line_1  => 'ADDR 1',
    address_city    => 'Segamat',
    phone           => '+60123456789',
    secret_question => "Mother's maiden name",
    secret_answer   => 'blah',
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
