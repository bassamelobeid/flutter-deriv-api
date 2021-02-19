#!/usr/bin/env perl
use strict;
use warnings;

use Time::Moment;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use Future::AsyncAwait;

use Log::Any qw($log);
use Getopt::Long qw(GetOptions);

use BOM::User;
use BOM::MT5::User::Async;

=head1 Name

mt5devel.pl -mt5 testing script.

=head1 Description

Script for testing general workflow for mt5 calls. User creation, Password changing, Deposit and Withdrawal

=cut

GetOptions(
    'l|log_level=s' => \my $log_level,
) or pod2usage(1);

$log_level ||= 'info';
require Log::Any::Adapter;
Log::Any::Adapter->import(qw(Stdout), log_level => $log_level);

my $loop = IO::Async::Loop->new;
$loop->new_future;

sub create_client {
    my (%args) = @_;
    my $email = delete($args{email}) or die 'need email';
    my $password        = delete($args{password}) // 'binary123';
    my $balance         = delete($args{balance})  // 100;
    my $currency        = delete($args{currency}) // 'USD';
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
        residence                => 'id',
        address_line_1           => '',
        address_line_2           => '',
        address_city             => '',
        address_state            => '',
        address_postcode         => '',
        phone                    => '',
        secret_question          => '',
        secret_answer            => '',
        non_pep_declaration_time => Date::Utility->new('20010108')->date_yyyymmdd,
    );
    my $vr = $user->create_client(
        %details,
        broker_code => 'VRTC',
    );
    $log->infof('Virtual account %s', $vr->loginid);
    $vr->save;
    my $cr = $user->create_client(
        %details,
        broker_code => 'CR',
    );
    $log->infof('Real account %s', $cr->loginid);
    $cr->set_default_account($currency);
    $cr->save;
    $cr->smart_payment(
        payment_type => 'cash_transfer',
        currency     => $currency,
        amount       => $balance,
        remark       => "prefilled balance",
    ) if $balance;
    return $cr;
}

(
    async sub {
        try {
            my $user   = BOM::User->new(email => 'mt5-setup@binary.com');
            my $client = $user ? $user->get_default_client() : create_client(
                email => 'mt5-setup@binary.com',
            );

            my $now = time;
            my ($main_password, $investor_password) = ('Abc1234de', 'Abc12345de');
            my $user_real = await BOM::MT5::User::Async::create_user({
                name           => "Test real $now",
                mainPassword   => $main_password,
                investPassword => $investor_password,
                group          => 'real\\svg',
                leverage       => 100
            });

            $log->infof('Created real user %s at %s', $user_real, Time::Moment->from_epoch($now)->to_string);
            $user->add_loginid($user_real->{login});

            my $user_demo = await BOM::MT5::User::Async::create_user({
                name           => "Test demo $now",
                mainPassword   => $main_password,
                investPassword => $investor_password,
                group          => 'demo\\svg',
                leverage       => 100
            });
            $log->infof('Created demo user %s at %s', $user_demo, Time::Moment->from_epoch($now)->to_string);
            $user->add_loginid($user_demo->{login});

            my $password_check = await BOM::MT5::User::Async::password_check({
                login    => $user_real->{login},
                password => $main_password,
                type     => 'main',
            });
            $log->infof('Password check result for %s is %s', $user_real->{login}, $password_check);

            my $password_change = await BOM::MT5::User::Async::password_change({
                login        => $user_real->{login},
                new_password => $main_password,
                type         => 'main',
            });
            $log->infof('Password change result for %s is %s', $user_real->{login}, $password_change);

            my $open_position_count = await BOM::MT5::User::Async::get_open_positions_count($user_real->{login});
            $log->infof('Open position count for %s is %s', $user_real->{login}, $open_position_count);

            my $txn_id       = int(rand(1000)) + 1;
            my $user_deposit = await BOM::MT5::User::Async::deposit({
                login   => $user_real->{login},
                amount  => "10",
                comment => $client->loginid . '_' . $user_real->{login} . '#' . $txn_id,
            });
            $log->infof('Deposit status from %s to %s is %s', $client->loginid, $user_real->{login}, $user_deposit);

            my $user_withdrawal = await BOM::MT5::User::Async::withdrawal({
                login   => $user_real->{login},
                amount  => "10",
                comment => $user_real->{login} . '_' . $client->loginid,
            });
            $log->infof('Withdrawal status from %s to %s is %s', $user_real->{login}, $client->loginid, $user_withdrawal);

            my $group_details = await BOM::MT5::User::Async::get_group('real\\svg');
            $log->infof('Group details for %s is %s', 'real\\svg', $group_details);

        } catch ($e) {
            $log->errorf('Failed - %s', $e);
        }
    })->()->get;

