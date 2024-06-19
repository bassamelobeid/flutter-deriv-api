use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance create_payout update_payout);
use BOM::User::Client;
use JSON;

# setting testing data up
my $email         = 'anemailfortesting+' . int(rand(10**6)) . '@deriv.com';
my $currency_code = 'EUR';
my $loginid       = 'MLT' . int(rand(10**6));

my $client = BOM::User::Client->rnew(
    account_opening_reason   => 'Speculative',
    address_city             => 'Cyber',
    address_line_1           => 'ADDR 1',
    address_line_2           => 'ADDR 2',
    address_postcode         => '',
    address_state            => 'State',
    broker_code              => 'MLT',
    citizen                  => 'at',
    client_password          => 'x',
    date_of_birth            => '1990-01-01',
    email                    => $email,
    first_name               => 'QA script',
    gender                   => '',
    last_name                => '$last_name',
    non_pep_declaration_time => time,
    phone                    => '+431400005430',
    place_of_birth           => 'at',
    residence                => 'at',
    salutation               => 'Ms',
    secret_answer            => 'dunno',
    secret_question          => "Mother's maiden name",
);

$client->loginid($loginid);
$client->save();

$client->set_default_account($currency_code);
$client->payment_free_gift(
    currency     => $currency_code,
    amount       => 10000,
    remark       => 'here is money (account created by script)',
    payment_type => 'free_gift'
);

my $user = BOM::User->create(
    email          => $email,
    password       => BOM::User::Password::hashpw("Abcd1234"),
    email_verified => 1,
    email_consent  => 1
);
$user->add_client($client);

# sanity check
ok $client->user, 'client is associated with an user';
is($client->landing_company->short, 'malta', 'landing company short name is malta');

BOM::Config::Runtime->instance->app_config->system->suspend->payout_freezing_funds(0);

my %payout_info = (
    loginid       => $loginid,
    currency_code => $currency_code,
    amount        => 2.0,
    trace_id      => 50001,
);

my $prefix = 'FREEZE FUNDS ENABLED: ';

sub create_payout_ok {
    my $override = shift;
    my $response = create_payout(%payout_info, $override->%*);

    is($response->code, 200, 'the payout has been created');
    like($response->content, qr/status="0"/, 'the content includes status=0');

    return $response;
}

sub update_payout_ok {
    my $override = shift;
    my $msg      = shift // 'the payout has been updated to ' . encode_json($override);
    my $response = update_payout(%payout_info, $override->%*);

    is($response->code, 200, $msg);
    like($response->content, qr/status="0"/, 'the content includes status=0');

    return $response;
}

sub balance_is {
    my $expected_balance = shift;
    my $msg              = shift;
    is(balance($loginid, {currency_code => $currency_code}), $expected_balance, $msg);
}

subtest $prefix . 'payout approved' => sub {
    $payout_info{trace_id} = 50000 + int(rand(9999));
    my $starting_balance = balance($loginid, {currency_code => $currency_code});

    create_payout_ok;
    balance_is($starting_balance - $payout_info{amount}, 'client has been debited at create payout');
    is $client->get_df_payouts_count, 1, 'The payout request is counted at creation';

    update_payout_ok({status => 'authorized'});
    balance_is($starting_balance - $payout_info{amount}, 'balance did not change at authorize payout');
    is $client->get_df_payouts_count, 1, 'The payout request is not changed at authorized';

    update_payout_ok({status => 'inprogress'});
    balance_is($starting_balance - $payout_info{amount}, 'balance did not change at update payout to inprogress');
    is $client->get_df_payouts_count, 1, 'The payout request is not changed at inprogress';

    update_payout_ok({status => 'approved'});
    balance_is($starting_balance - $payout_info{amount}, 'balance did not change at update payout to inprogress');
    is $client->get_df_payouts_count, 0, 'The payout request is removed at approved';
};

subtest $prefix . 'payout cancelled' => sub {
    $payout_info{trace_id} = 50000 + int(rand(9999));
    my $starting_balance = balance($loginid, {currency_code => $currency_code});

    create_payout_ok;
    balance_is($starting_balance - $payout_info{amount}, 'client has been debited at create payout');
    is $client->get_df_payouts_count, 1, 'The payout request is counted at creation';

    update_payout_ok({status => 'cancelled'});
    balance_is($starting_balance, 'client has been refunded at cancel payout');
    is $client->get_df_payouts_count, 0, 'The payout request is removed at cancelled';
};

subtest $prefix . 'payout rejected' => sub {
    $payout_info{trace_id} = 50000 + int(rand(9999));
    my $starting_balance = balance($loginid, {currency_code => $currency_code});

    create_payout_ok;
    balance_is($starting_balance - $payout_info{amount}, 'client has been debited at create payout');
    is $client->get_df_payouts_count, 1, 'The payout request is counted at creation';

    update_payout_ok({status => 'rejected'});
    balance_is($starting_balance, 'client has been refunded at reject payout');
    is $client->get_df_payouts_count, 0, 'The payout request is removed at rejected';
};

done_testing;
