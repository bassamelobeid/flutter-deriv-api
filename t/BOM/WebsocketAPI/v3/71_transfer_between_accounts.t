use strict;
use warnings;
use Test::More;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use TestHelper qw/test_schema build_mojo_test call_mocked_client/;
use Cache::RedisDB;
use Test::Exception;
use Test::FailWarnings;

use BOM::Database::Model::AccessToken;
use BOM::System::Password;
use BOM::Platform::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::Transaction;

## do not send email
use Test::MockModule;
my $client_mocked = Test::MockModule->new('BOM::Platform::Client');
$client_mocked->mock('add_note', sub { return 1 });
my $email_mocked = Test::MockModule->new('BOM::Platform::Email');
$email_mocked->mock('send_email', sub { return 1 });

{
    ## not malta is not allowed
    my $t = build_mojo_test();

    my $email    = 'abc@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::System::Password::hashpw($password);

    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
    });
    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $client_vr->email($email);
    $client_vr->save;
    $client_cr->email($email);
    $client_cr->save;
    my $vr_1 = $client_vr->loginid;
    my $cr_1 = $client_cr->loginid;

    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;

    $user->add_loginid({loginid => $vr_1});
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    my $token = BOM::Database::Model::AccessToken->new->create_token($client_cr->loginid, 'Test Token', 'read', 'payments');
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
                "account_from"              => $client_cr->loginid,
                "account_to"                => $client_vr->loginid,
                "currency"                  => "EUR",
                "amount"                    => 100
            }})->message_ok;
    my $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /The account transfer is unavailable/, 'The account transfer is unavailable';

    $t->finish_ok;
}

{
    my $t = build_mojo_test();

    $ENV{'REDIS_CACHE_SERVER'} = $ENV{'REDIS_CACHE_SERVER'} // '127.0.0.1:6379';
    Cache::RedisDB->redis();
    Cache::RedisDB->set('COMBINED_REALTIME', 'frxEURUSD', {quote => 1});

    my $email    = 'bce@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::System::Password::hashpw($password);

    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MF',
    });
    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });
    $client_mf->email($email);
    $client_mf->save;
    $client_mlt->email($email);
    $client_mlt->save;
    my $vr_1 = $client_mf->loginid;
    my $cr_1 = $client_mlt->loginid;

    my $user = BOM::Platform::User->create(
        email    => $email,
        password => $hash_pwd
    );
    $user->save;

    $user->add_loginid({loginid => $vr_1});
    $user->add_loginid({loginid => $cr_1});
    $user->save;

    my $token = BOM::Database::Model::AccessToken->new->create_token($client_mlt->loginid, 'Test Token', 'read', 'payments');
    $t = $t->send_ok({json => {authorize => $token}})->message_ok;

    my ($res, $call_params) = call_mocked_client(
        $t,
        {
            "transfer_between_accounts" => "1",
            "account_from"              => $client_mlt->loginid,
            "account_to"                => $client_mf->loginid,
            "currency"                  => "EUR",
            "amount"                    => 100
        });
    ok $call_params->{token};
    is $res->{msg_type}, 'transfer_between_accounts';
    ok $res->{error}->{message} =~ /The account transfer is unavailable. Please deposit to your account/, 'Not deposited into any account yet';

    $client_mf->set_default_account('EUR');
    $client_mlt->set_default_account('EUR');

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
                "account_from"              => $client_mlt->loginid,
                "account_to"                => 'MLT999999',
                "currency"                  => "EUR",
                "amount"                    => 100
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /The account transfer is unavailable for your account/, 'The account transfer is unavailable for your account';

    $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
    ok $client_mlt->get_status('disabled'), 'is disabled due to tamper';
    $client_mlt->clr_status('disabled');
    $client_mlt->save();

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
                "account_from"              => $client_mlt->loginid,
                "account_to"                => $client_mf->loginid,
                "currency"                  => "EUR",
                "amount"                    => 100
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{error}->{message} =~ /The maximum amount you may transfer/, 'The maximum amount you may transfer';

    ## test for failure
    foreach my $amount ('', -1, 0.01) {
        $t = $t->send_ok({
                json => {
                    "transfer_between_accounts" => "1",
                    "account_from"              => $client_mlt->loginid,
                    "account_to"                => $client_mf->loginid,
                    "currency"                  => "EUR",
                    (defined $amount) ? (amount => $amount) : ()}})->message_ok;
        $res = decode_json($t->message->[1]);
        if (defined $amount and $amount ne '') {
            ok $res->{error}->{message} =~ /Invalid amount/, "test amount $amount";
        } else {
            ok $res->{error}->{message} =~ /Input validation failed: amount/, "test amount " . ($amount // 'undef');
        }
    }

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is scalar(@{$res->{accounts}}), 2, 'two accounts';
    my ($tmp) = grep { $_->{loginid} eq $cr_1 } @{$res->{accounts}};
    ok $tmp->{balance} == 0;

    $client_mlt->payment_free_gift(
        currency => 'EUR',
        amount   => 100,
        remark   => 'free gift',
    );

    $client_mlt->clr_status('cashier_locked');    # clear locked
    $client_mlt->save();

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    is $res->{msg_type}, 'transfer_between_accounts';
    is scalar(@{$res->{accounts}}), 2, 'two accounts';
    ($tmp) = grep { $_->{loginid} eq $cr_1 } @{$res->{accounts}};
    ok $tmp->{balance} == 100;

    $t = $t->send_ok({
            json => {
                "transfer_between_accounts" => "1",
                "account_from"              => $client_mlt->loginid,
                "account_to"                => $client_mf->loginid,
                "currency"                  => "EUR",
                "amount"                    => 10
            }})->message_ok;
    $res = decode_json($t->message->[1]);
    ok $res->{transfer_between_accounts}, 'transfer_between_accounts is ok';
    is $res->{client_to_loginid},         $client_mf->loginid, 'transfer_between_accounts to client is ok';
    is $res->{client_to_full_name},       $client_mf->full_name, 'transfer_between_accounts to client name is ok';

    ## after withdraw, check both balance
    $client_mlt = BOM::Platform::Client->new({loginid => $client_mlt->loginid});
    $client_mf  = BOM::Platform::Client->new({loginid => $client_mf->loginid});
    ok $client_mlt->default_account->balance == 90, '-10';
    ok $client_mf->default_account->balance == 10,  '+10';
}

done_testing();
