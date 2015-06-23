#!/usr/bin/perl

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Exception;

use Date::Utility;
use BOM::Platform::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $rose_client = BOM::Platform::Client->new({loginid => 'CR2002'});
my $loginid     = $rose_client->loginid;
my $account     = $rose_client->default_account;

my $client;
lives_ok { $client = BOM::Platform::Client->new({loginid => $loginid}) } 'Can create client object.';

$client->payment_legacy_payment(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'ewallet',
);

subtest 'no doughflow payment for client - allow for payment agent withdrawal' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal();
    is $allow_withdraw, 1, 'no doughflow payment, allow payment agent withdrawal';
};

$client->payment_doughflow(
    currency     => 'USD',
    amount       => 1,
    remark       => 'here is money',
    payment_type => 'external_cashier',
);

subtest 'doughflow payment exists for client - not allow for payment agent withdrawal' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal();
    is $allow_withdraw, undef, 'doughflow payment exist, not allow for payment agent withdrawal';
};

my $expire_date_before = Date::Utility->new(time() - 86400)->date_yyyymmdd;
$client->payment_agent_withdrawal_expiration_date($expire_date_before);
subtest 'doughflow payment exists for client - with invalid payment_agent_withdrawal_expiration_date' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal();
    is $allow_withdraw, undef, 'with invalid payment_agent_withdrawal_expiration_date';
};

my $expire_date_after = Date::Utility->new(time() + 86400)->date_yyyymmdd;
$client->payment_agent_withdrawal_expiration_date($expire_date_after);
subtest 'doughflow payment exists for client - with valid payment_agent_withdrawal_expiration_date' => sub {
    my $allow_withdraw = $client->allow_paymentagent_withdrawal();
    is $allow_withdraw, 1, ' with valid payment_agent_withdrawal_expiration_date';
};

