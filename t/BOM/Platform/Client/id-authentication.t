use strict;
use warnings;

use Email::Sender::Transport::Test;
use Test::Most 'no_plan';
use Test::FailWarnings;
use File::Spec;
use Test::MockModule;
use Test::Exception;
use BOM::User;
use XML::Simple;

use BOM::Platform::Email;

$ENV{EMAIL_SENDER_TRANSPORT} = 'Test';

use BOM::User::Client;
use BOM::Platform::Context qw(request);
use BOM::Platform::Client::IDAuthentication;

use BOM::Test::Helper::Client qw(create_client);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $xml              = XML::Simple->new;
my $compops_email    = 'x-compops@deriv.com';
my $compliance_email = 'compliance@deriv.com';
my $password         = 'Abc123';
my $hash_pwd         = BOM::User::Password::hashpw($password);

sub email_list {
    my $transport = Email::Sender::Simple->default_transport;
    my @emails    = map { +{$_->{envelope}->%*, subject => '' . $_->{email}->get_header('Subject'),} } $transport->deliveries;
    $transport->clear_deliveries;
    @emails;
}

subtest 'Constructor' => sub {
    subtest 'No Client' => sub {
        throws_ok(sub { BOM::Platform::Client::IDAuthentication->new() }, qr/Missing required arguments: client/, "Constructor dies with no client");
    };
    subtest 'With Client' => sub {
        my $c   = create_client();
        my $obj = BOM::Platform::Client::IDAuthentication->new({client => $c});
        isa_ok($obj, "BOM::Platform::Client::IDAuthentication", "Constructor ok with client");
    };
};

subtest 'Virtual accounts' => sub {
    my $user_client_vr = BOM::User->create(
        email          => 'vr@binary.com',
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    my $c = create_client('VRTC');
    $user_client_vr->add_client($c);

    my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
    ok !$v->client->is_first_deposit_pending, 'No tracking of first deposit for virtual accounts';
    is($v->run_authentication, undef, "run_authentication for VRTC ok");

};
subtest "CR accounts" => sub {
    my $user_client_cr = BOM::User->create(
        email          => 'cr@binary.com',
        password       => BOM::User::Password::hashpw('jskjd8292922'),
        email_verified => 1,
    );

    my $c = create_client('CR');
    $user_client_cr->add_client($c);

    my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
    ok $v->client->is_first_deposit_pending, 'First deposit tracking for CR account';

    $v->run_authentication();

    ok !$v->client->status->cashier_locked, "CR client not cashier locked following run_authentication";
    ok !$v->client->status->unwelcome,      "CR client not unwelcome following run_authentication";
};

subtest 'MLT accounts' => sub {
    subtest 'Not age verified prior to run_authentication' => sub {
        my $user_client_mlt = BOM::User->create(
            email          => 'mlt@binary.com',
            password       => BOM::User::Password::hashpw('jskjd8292922'),
            email_verified => 1,
        );

        my $c = create_client('MLT');
        $user_client_mlt->add_client($c);

        $c->status->clear_age_verification;

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MLT account';

        $v->run_authentication;

        ok !$v->client->fully_authenticated,      'Not fully authenticated';
        ok !$v->client->status->age_verification, 'Not age verified';
        ok $v->client->status->unwelcome,         'Is unwelcome';
        ok !$v->client->status->cashier_locked,   'Not cashier_locked';
    };
    subtest 'Age verified prior to run_authentication' => sub {
        my $user_client_mlt = BOM::User->create(
            email          => 'mlt2@binary.com',
            password       => BOM::User::Password::hashpw('jskjd8292922'),
            email_verified => 1,
        );

        my $c = create_client('MLT');
        $user_client_mlt->add_client($c);

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MLT account';

        $v->run_authentication;

        ok !$v->client->fully_authenticated,    'Not fully authenticated';
        ok !$v->client->status->unwelcome,      'Not unwelcome';
        ok !$v->client->status->cashier_locked, 'Not cashier_locked';
    };
};

subtest 'MF accounts' => sub {
    subtest "Not authenticated prior to run_authentication" => sub {
        my $user_client_mf = BOM::User->create(
            email          => 'mf@binary.com',
            password       => BOM::User::Password::hashpw('jskjd8292922'),
            email_verified => 1,
        );

        my $c = create_client('MF');
        $user_client_mf->add_client($c);

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MF account';

        $c->set_authentication('ID_DOCUMENT', {status => 'pending'});
        $v->run_authentication;

        ok !$v->client->fully_authenticated, 'Not fully authenticated';
        ok !$v->client->status->unwelcome,   "Unwelcome not applied as being handled by Payops-IT team for MF clients";
    };
    subtest "Authenticated prior to run_authentication" => sub {
        my $user_client_mf = BOM::User->create(
            email          => 'mf2@binary.com',
            password       => BOM::User::Password::hashpw('jskjd8292922'),
            email_verified => 1,
        );

        my $c = create_client('MF');
        $user_client_mf->add_client($c);

        my $v = BOM::Platform::Client::IDAuthentication->new(client => $c);
        ok $v->client->is_first_deposit_pending, 'First deposit tracking for MF account';

        $c->set_authentication('ID_DOCUMENT', {status => 'pass'});

        $v->run_authentication;

        ok $v->client->fully_authenticated, 'Fully authenticated';
        ok !$v->client->status->unwelcome,  "Not unwelcome";
    };
};

sub create_user_and_clients {
    my $brokers = shift;
    my $email   = shift;
    my $details = shift;

    my $user = BOM::User->create(
        email    => $email // 'mx_test' . rand(999) . '@binary.com',
        password => $hash_pwd
    );

    my $clients = {};

    for my $broker (@$brokers) {
        my $c = create_client($broker, undef, $details);
        $clients->{$broker} = $c;
        $user->add_client($c);
    }

    return $clients;
}

1;
