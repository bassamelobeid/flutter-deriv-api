use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(balance create_payout update_payout);
use BOM::User::Client;
use Format::Util::Numbers qw/financialrounding/;
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

my %payout_info = (
    loginid       => $loginid,
    currency_code => $currency_code,
    amount        => 2.0,
    trace_id      => 50001,
);

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

for my $status (qw(enabled disabled)) {
    my $prefix = uc 'freezing funds ' . $status . ': ';
    BOM::Config::Runtime->instance->app_config->system->suspend->payout_freezing_funds($status eq 'disabled');
    is($client->is_payout_freezing_funds_enabled, $status eq 'enabled', 'freezing funds is ' . $status);

    subtest $prefix . 'update non-existent payout to inprogress' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        my $response         = update_payout(%payout_info, status => 'inprogress');
        is($response->code, 200, 'updating a non-existent payout to inprogress returns http code 200');
        balance_is($starting_balance - $payout_info{amount}, 'the client has been debited');
    };

    subtest $prefix . 'update payout to inprogress twice' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});

        create_payout_ok;
        update_payout_ok({status => 'authorized'});
        update_payout_ok({status => 'inprogress'});

        my $response = update_payout(%payout_info, status => 'inprogress');
        if ($client->is_payout_freezing_funds_enabled) {
            # the client has been debiten on payout_created
            # the code search for a transaction transaction_type=withdrawal_hold and returns 200 if found
            is($response->code, 200, 'updating the payout to inprogress twice returns http code 200');
        } else {
            # when the client is debited on payout_inprogress, the transaction shall not be duplicated
            # therefore, it's easy to return 400 the second time
            is($response->code, 400, 'updating the payout to inprogress twice returns http code 400');
            like($response->content,
                qr/Detected duplicate transaction \[DoughFlow withdrawal trace_id=$payout_info{trace_id} payment_method=VISA\] while processing request for withdrawal with trace id $payout_info{trace_id} and transaction id /
            );
        }

        balance_is($starting_balance - $payout_info{amount}, 'the client has been debited only once');
    };

    subtest $prefix . 'cancel non-existent payout' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        update_payout_ok({status => 'cancelled'});
        balance_is($starting_balance, 'the balance has not been touched');
    };

    subtest $prefix . 'cancel payout twice' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        create_payout_ok;
        update_payout_ok({status => 'cancelled'});
        update_payout_ok({status => 'cancelled'});
        balance_is($starting_balance, 'the balance has not been touched');
    };

    subtest $prefix . 'reject non-existent payout' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        my $response         = update_payout(%payout_info, status => 'rejected');
        like($response->content,
            qr/A withdrawal reversal was requested for DoughFlow trace ID $payout_info{trace_id}, but no corresponding original withdrawal could be found with that trace ID/
        );
        is($response->code,   400,                                                  'rejecting a non-existent payout returns http code 400');
        is($starting_balance, balance($loginid, {currency_code => $currency_code}), 'the balance has not been touched');
    };

    subtest $prefix . 'reject payout twice' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        create_payout_ok;
        update_payout_ok({status => 'authorized'});
        update_payout_ok({status => 'inprogress'});
        balance_is($starting_balance - $payout_info{amount}, 'the client has been debited');
        update_payout_ok({status => 'rejected'});
        balance_is($starting_balance, 'the client has been refunded');

        my $response = update_payout(%payout_info, status => 'rejected');
        like($response->content,
            qr/A withdrawal reversal was requested for DoughFlow trace ID $payout_info{trace_id}, but multiple corresponding original withdrawals were found with that trace ID/
        );
        is($response->code, 400, 'rejecting the payout twice returns http code 400');
        balance_is($starting_balance, 'the client has been refunded only once');
    };

    subtest $prefix . 'reject a payout with changed amount' => sub {
        $payout_info{trace_id} = 50000 + int(rand(10**6));
        my $starting_balance = balance($loginid, {currency_code => $currency_code});
        create_payout_ok;
        update_payout_ok({status => 'authorized'});
        update_payout_ok({status => 'inprogress'});

        my $balance_after_payout = $starting_balance - $payout_info{amount};
        balance_is($balance_after_payout, 'the client has been debited');

        my $new_amount = $payout_info{amount} + 2.0;
        my $amount_str = financialrounding('amount', $payout_info{currency_code}, $new_amount);
        $payout_info{amount} = $new_amount;

        my $response = update_payout(%payout_info, status => 'rejected');
        like($response->content,
            qr/A withdrawal reversal request for DoughFlow trace ID $payout_info{trace_id} was made in the amount of $payout_info{currency_code} $amount_str, but this does not match the original DoughFlow withdrawal request amount/
        );
        is($response->code, 400, 'rejecting the payout twice returns http code 400');
        balance_is($balance_after_payout, 'the client has not been refunded');
    };
}

done_testing;
