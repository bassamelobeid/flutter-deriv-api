#!/usr/bin/env perl
use strict;
use warnings;

=head1 NAME

p2p-setup.pl - prepares environment for P2P testing.

=head1 SYNOPSIS

    p2p-setup.pl
    p2p-setup.pl -r     # resets the list of clients allowed to access P2P
    p2p-setup.pl -o     # creates an order

=head1 DESCRIPTION

This script does the following:

=over 4

=item * creates an oauth app with payments and read scope, for mobile access

=item * creates an escrow account for CR USD

=item * creates an advertiser with a 5k balance, and a pair of buy/sell adverts

=item * creates a client

=item * turns on P2P functionality in the backoffice

=item * adds the client and advertiser to the P2P enabled list

=item * create orders (optional)

=back

It will report the email addresses, account IDs and auth tokens for testing.

Each time the script runs, it will create a new client and advertiser pair. The
escrow account and OAuth app are only created once.

=cut

use Time::Moment;
use Getopt::Long;
use Log::Any::Adapter qw(Stdout), log_level => 'debug';
use Log::Any qw($log);

use BOM::User;
use BOM::User::Client;
use BOM::Platform::Token::API;
use BOM::Config::Runtime;
use BOM::Config::Chronicle;
use BOM::Database::AuthDB;

$SIG{__DIE__} = sub {
    return if $^S;
    $log->errorf('Fatal error: %s', @_);
    exit(1);
};

# File calling arguments
GetOptions(
    "r|reset-clients" => \(my $reset_clients = 0),
    "s|sendbird" => \(my $use_sendbird = 0),
    "o|order" => \(my $create_order = 0),
);

unless ($use_sendbird) {
    no strict 'refs';
    no warnings;
    *WebService::SendBird::create_user = sub { 
        return WebService::SendBird::User->new(
            api_client => 1,
            user_id    => 'dummy',
            session_tokens => [{
                'session_token' => 'dummy',
                'expires_at'    => time + 7200 
            }]            
        );
    };
    $log->info('Sendbird is disabled. You can enable with --sendbird 1');
}

sub section_title {
    print "\n" . '-' x 25 . ' ' . shift . ' ' . '-' x 25 . "\n";
}

sub create_client {
    my (%args) = @_;
    my $email = delete($args{email}) or die 'need email';
    my $password = delete($args{password}) // 'binary123';
    my $balance  = delete($args{balance})  // 0;
    my $currency = delete($args{currency}) // 'USD';
    my $hashed_password = BOM::User::Password::hashpw($password);

    $log->infof('Creating user with email %s', $email);

    my $user = BOM::User->create(
        email              => $email,
        password           => $hashed_password,
        email_verified     => 1,
        has_social_signup  => 0,
        email_consent      => 1,
        app_id             => 1,
        date_first_contact => Time::Moment->now->strftime('%Y-%m-%d'),
    );
    $log->infof('User %s', $user->id);

    my %details = (
        client_password          => $hashed_password,
        first_name               => '',
        last_name                => '',
        myaffiliates_token       => '',
        email                    => $email,
        residence                => 'za',
        address_line_1           => '1 sesame st',
        address_line_2           => '',
        address_city             => 'cyberjaya',
        address_state            => '',
        address_postcode         => '',
        phone                    => '',
        secret_question          => '',
        secret_answer            => '',
        non_pep_declaration_time => time,
    );

    my $vr = $user->create_client(
        %details,
        broker_code => 'VRTC',
    );
    $vr->save;
    $log->infof('Virtual account: %s', $vr->loginid);

    my $cr = $user->create_client(
        %details,
        broker_code => 'CR',
    );
    $cr->set_default_account($currency);
    $cr->save;
    $log->infof('Real account: %s', $cr->loginid);
    $cr->smart_payment(
        payment_type => 'cash_transfer',
        currency     => $currency,
        amount       => $balance,
        remark       => "prefilled balance",
    ) if $balance;
    return $cr;
}

sub token_for_client {
    my ($client) = @_;
    BOM::Platform::Token::API->new->create_token($client->loginid, 'api', ['payments', 'read'],);
}

{
    my $app_user = BOM::User->new(email => 'p2p-cashier@binary.com')
        || (
        section_title('P2P Cashier')
        && create_client(
            email => 'p2p-cashier@binary.com',
        )->user
        );

    section_title('OAuth App');
    
    my $app_id = 1408;
    my $auth_db = BOM::Database::AuthDB::rose_db()->dbic;
    
    my $app = $auth_db->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT * FROM oauth.apps WHERE id = $app_id");
        });
    
    if ($app) {
        $log->infof('Found existing OAuth app ID %d - %s', $app->{id}, $app);
    }
    else {
        $app = $auth_db->run(
            fixup => sub {
                $_->selectrow_hashref('INSERT INTO oauth.apps (id, binary_user_id, name, scopes, redirect_uri, verification_uri) VALUES (?,?,?,?,?,?) RETURNING *', 
                    undef,
                    $app_id, $app_user->id, 'P2P Cashier', [qw(read payments)], 'deriv://dp2p/redirect', 'https://p2p-cashier.deriv.com')
            });
        $log->infof('Created OAuth app ID %d - %s', $app->{id}, $app);
    }
}

# ===== Escrow =====
section_title('Escrow Account');
my $escrow_user = BOM::User->new(email => 'escrow@binary.com') || create_client(
    email => 'escrow@binary.com',
)->user;
my @escrow_ids = grep { !/^VR/ } $escrow_user->loginids;
$log->infof('Escrow is %s', \@escrow_ids);

my $idx = time;

# ===== Advertiser =====
section_title('Advertiser Account');
my $advertiser = create_client(
    email   => 'advertiser+' . $idx . '@binary.com',
    balance => 5000,
);
$log->infof('Advertiser is %s - Token: %s', $advertiser->loginid, token_for_client($advertiser));

# ===== Client =====
section_title('Client Account');
my $client = create_client(
    email => 'client+' . $idx . '@binary.com',
);
$log->infof('Client is %s - Token: %s', $client->loginid, token_for_client($client));

# ===== App Config =====
section_title('App Config');
my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

my $all_clients = $app_config->payments->p2p->clients;
my $new_clients = [$advertiser->loginid, $client->loginid];
push(@$all_clients, @$new_clients);

$app_config->set({'payments.p2p.enabled'                 => 1});
$app_config->set({'payments.p2p.available'               => 1});
$app_config->set({'system.suspend.p2p'                   => 0});
$app_config->set({'payments.p2p.clients'                 => $reset_clients ? $new_clients : $all_clients});
$app_config->set({'payments.p2p.escrow'                  => \@escrow_ids});
$app_config->set({'payments.p2p.limits.maximum_advert'   => 3000});
$app_config->set({'payments.p2p.available_for_countries' => [qw(za ng)]});

$log->infof('App config applied');
$log->infof('P2P devops status originally:  %s', $app_config->system->suspend->p2p   ? 'off' : 'on');
$log->infof('P2P payment status originally: %s', $app_config->payments->p2p->enabled ? 'on'  : 'off');
$log->infof('Maximum advert configured is %s',   BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_advert);
$log->infof('Maximum order  configured is %s',   BOM::Config::Runtime->instance->app_config->payments->p2p->limits->maximum_order);

# ===== Advertiser Create =====
section_title('Advertiser Create');
unless ($advertiser->p2p_advertiser_info) {
    $advertiser->p2p_advertiser_create(name => 'advertiser '.$advertiser->loginid);
}
$advertiser->p2p_advertiser_update(
    is_listed   => 1,
    is_approved => 1,
);
$advertiser->save;
$log->infof('Advertiser info: %s', $advertiser->p2p_advertiser_info);

$advertiser->p2p_advert_create(
    account_currency => 'USD',
    local_currency   => 'ZAR',
    amount           => 3000,
    rate             => 14500,
    type             => 'buy',
    expiry           => 2 * 60 * 60,
    min_order_amount => 10,
    max_order_amount => 100,
    payment_method   => 'bank_transfer',
    description      => 'Please contact via whatsapp 1234',
    country          => 'za',
);

my $advert_sell = $advertiser->p2p_advert_create(
    account_currency => 'USD',
    local_currency   => 'ZAR',
    amount           => 3000,
    rate             => 13500,
    type             => 'sell',
    expiry           => 2 * 60 * 60,
    min_order_amount => 10,
    max_order_amount => 100,
    payment_method   => 'bank_transfer',
    payment_info     => 'Transfer to account 000-1111',
    contact_info     => 'Please contact via whatsapp 1234',
    description      => 'Please contact via whatsapp 1234',
    country          => 'za',
);

# ===== Orders Create =====

if ($create_order) {
    section_title('Creating Buy Order');

    my $order_buy = $client->p2p_order_create(
        advert_id => $advert_sell->{id},
        amount    => $advert_sell->{min_order_amount}
    );

    $log->infof('Order info: %s', $order_buy);

    section_title('Creating Sell Order');
    
    # We'll create an ad for client so we can have a sell order as well
    unless ($client->p2p_advertiser_info) {
        $client->p2p_advertiser_create(name => 'advertiser '.$client->loginid);
    }
    $client->p2p_advertiser_update(
        is_listed   => 1,
        is_approved => 1,
    );
    $client->save;

    # Create ad
    my $advert_buy = $client->p2p_advert_create(
        account_currency => 'USD',
        local_currency   => 'ZAR',
        amount           => 3000,
        rate             => 14500,
        type             => 'buy',
        expiry           => 2 * 60 * 60,
        min_order_amount => 10,
        max_order_amount => 100,
        payment_method   => 'bank_transfer',
        description      => 'Please contact via whatsapp 1234',
        country          => 'za',
    );

    # Sell order
    my $order_sell = $advertiser->p2p_order_create(
        advert_id => $advert_buy->{id},
        amount    => $advert_buy->{min_order_amount},
        payment_info => 'Come home with one of those giant checks',
        contact_info => 'Yell my name three times'
    );

    $log->infof('Sell Order info: %s', $order_sell);
}

section_title('Success!');
