package t::cryptoservice;

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Mojolicious::Lite;

use BOM::User;
use BOM::User::Password;
use BOM::Platform::CryptoCashier::Iframe::Controller;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use BOM::Platform::Client::CashierValidation;

get '/btc/handshake' => sub {
    my $c = shift;

    my ($currency) = ($c->req->url =~ '/([a-zA-Z0-9]{2,20})/handshake');

    return $c->render(
        text   => 'Invalid request.',
        status => 200,
    ) unless $currency;

    my $params = $c->req->params->to_hash;

    my ($token, $loginid, $action) = @$params{qw/token loginid action/};

    return $c->render(
        text   => 'Invalid request.',
        status => 200,
    ) if (not $token or not $loginid or not $action);

    my $client = BOM::User::Client->new({
        loginid      => $loginid,
        db_operation => 'replica'
    });

    my $rule_engine = BOM::Rules::Engine->new(client => $client);
    my $validation  = BOM::Platform::Client::CashierValidation::validate(
        loginid     => $loginid,
        action      => $action,
        is_internal => 0,
        rule_engine => $rule_engine
    );
    return $c->render(
        text   => $validation->{error}->{message_to_client},
        status => 200,
    ) if $validation->{error};

    my $res = BOM::Platform::CryptoCashier::Iframe::Controller::_check_handoff_token_key($loginid, $token);

    if ($res->{is_expired}) {
        return $c->render(
            text   => 'Your current cashier session has expired. Please start again.',
            status => 200,
        );
    } elsif ($res->{is_invalid}) {
        # no handshake or wrong session
        return $c->render(
            text   => 'Invalid request.',
            status => 200,
        );
    }

    $c->render(text => 'Success');
};

my ($t, $test_client, $user, $loginid);
subtest 'handshake failures' => sub {
    $t = Test::Mojo->new('t::cryptoservice');
    # no params
    $t->get_ok('/btc/handshake')->status_is(200)->content_like(qr/Invalid request/);
    # only token
    $t->get_ok('/btc/handshake?token=dummy')->status_is(200)->content_like(qr/Invalid request/);
    # no action
    $t->get_ok('/btc/handshake?token=dummy&loginid=CR994221')->status_is(200)->content_like(qr/Invalid request/);
    # invalid loginid
    $t->get_ok('/btc/handshake?token=dummy&loginid=CR994221&action=deposit')->status_is(200)->content_like(qr/Invalid account/);

    my $email    = 'abc@binary.com';
    my $password = 'jskjd8292922';
    my $hash_pwd = BOM::User::Password::hashpw($password);
    $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    $test_client->email($email);
    $test_client->save;

    $loginid = $test_client->loginid;
    $user    = BOM::User->create(
        email    => $email,
        password => $hash_pwd
    );

    $user->add_loginid($loginid);

    # no default account
    $t->get_ok("/btc/handshake?token=dummy&loginid=$loginid&action=deposit")->status_is(200)->content_like(qr/Please set the currency./);
};

subtest 'check handoff token' => sub {
    my $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($loginid);

    subtest 'token valid for first time' => sub {
        $test_client->set_default_account('BTC');
        $test_client->save;
        $t->get_ok("/btc/handshake?token=$token&loginid=$loginid&action=deposit")->status_is(200)->content_like(qr/Success/);
    };

    subtest 'token cannot be use more than once' => sub {
        $t->get_ok("/btc/handshake?token=$token&loginid=$loginid&action=deposit")->status_is(200)->content_like(qr/Invalid request./);
    };
};

subtest 'check client status' => sub {
    my $token = BOM::Platform::CryptoCashier::Iframe::Controller::_get_handoff_token_key($loginid);

    subtest 'cannot deposit when client is unwelcome' => sub {
        $test_client->status->set('unwelcome', 'test', 'testing crypto deposit when client is unwelcome');
        $test_client->save;
        $t->get_ok("/btc/handshake?token=$token&loginid=$loginid&action=deposit")->status_is(200)
            ->content_like(qr/Your account is restricted to withdrawals only./);
        $test_client->status->clear_unwelcome;
        $test_client->save;
    };

    subtest 'cannot deposit when client is disabled' => sub {
        $test_client->status->set('disabled', 'test', 'testing crypto deposit when client is disabled');
        $test_client->save;
        $t->get_ok("/btc/handshake?token=$token&loginid=$loginid&action=deposit")->status_is(200)->content_like(qr/Your account is disabled./);
        $test_client->status->clear_disabled;
        $test_client->save;
    };

    subtest 'Withdrawal fails if client status = withdrawal_locked' => sub {
        $test_client->status->set('withdrawal_locked', 'test', 'testing crypto withdrawal when client has withdrawal_locked status');
        $test_client->save;
        $t->get_ok("/btc/handshake?token=$token&loginid=$loginid&action=withdraw")->status_is(200)
            ->content_like(qr/Your account is locked for withdrawals./);
        $test_client->status->clear_cashier_locked;
        $test_client->save;
    };
};

done_testing();
