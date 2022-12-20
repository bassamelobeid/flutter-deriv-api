#!/usr/bin/perl

#########################################################################
# update_mt5_trading_rights_and_status                                  #
# This script is used to gather the clients with poa_pending status     #
# If the poa_pending status is 5 days for vanuatu or 10 days for bvi    #
# we update the status to poa_failed and update their trading rights    #
# to red flag in mt5                                                    #
#########################################################################

use strict;
use warnings;
use BOM::Database::UserDB;
use Date::Utility;
use BOM::Config;
use BOM::User::Client;
use List::Util qw(min max);
use Syntax::Keyword::Try;
use BOM::Platform::Event::Emitter;
use Brands;
use JSON::MaybeXS              qw(decode_json);
use DataDog::DogStatsd::Helper qw(stats_event);

use constant BVI_EXPIRATION_DAYS     => 10;
use constant BVI_WARNING_DAYS        => 8;
use constant DB_OFFSET_DAYS          => 2;      # Need to consider the accounts created on the day until 23:59:59
use constant VANUATU_EXPIRATION_DAYS => 5;
use constant DB_OFFSET_DAYS          => 2;      # Need to consider the accounts created on the day until 23:59:59
use constant VANUATU_WARNING_DAYS    => 3;
use constant COLOR_RED               => 255;    # BGR (0,0,255)

my $userdb = BOM::Database::UserDB::rose_db();
my $now    = Date::Utility->today;
my $users  = $userdb->dbic->run(
    fixup => sub {
        $_->selectall_arrayref('select * from users.get_loginids_poa_timeframe(?, ?)',
            undef, undef, $now->minus_time_interval(min(BVI_WARNING_DAYS, DB_OFFSET_DAYS) . 'd')->db_timestamp);
    });

stats_event('StatusUpdate', 'Gathered ' . scalar(@$users) . ' users from DB', {alert_type => 'info'});
my $bvi_warning_timestamp        = $now->minus_time_interval(BVI_WARNING_DAYS . 'd');
my $bvi_expiration_timestamp     = $now->minus_time_interval(BVI_EXPIRATION_DAYS . 'd');
my $vanuatu_warning_timestamp    = $now->minus_time_interval(VANUATU_WARNING_DAYS . 'd');
my $vanuatu_expiration_timestamp = $now->minus_time_interval(VANUATU_EXPIRATION_DAYS . 'd');

my @clients_warning;
my @clients_expired;
my @clients_failed;
my %parsed_mt5_account;
my %parsed_binary_user_id;

# We need to disable all mt5 accounts which are under the same jurisdiction
sub get_mt5_accounts_under_same_jurisdiction {

    my ($user, $jurisdiction) = @_;
    my @mt5_accounts;
    my $loginid_details = $user->loginid_details;

    foreach my $account (keys $loginid_details->%*) {

        next unless ($loginid_details->{$account}{platform} // '') eq 'mt5' && ($loginid_details->{$account}{account_type} // '') eq 'real';

        if ($loginid_details->{$account}{attributes}{group} =~ m{$jurisdiction}) {
            push @mt5_accounts, $account;
        }
    }

    return @mt5_accounts;
}

foreach my $data (@$users) {
    my ($loginid, $binary_user_id, $creation_stamp, $status, $platform, $account_type, $currency, $attributes) = @$data;

    next if $parsed_binary_user_id{$binary_user_id};

    $attributes     = decode_json($attributes);
    $creation_stamp = Date::Utility->new($creation_stamp);
    stats_event('StatusUpdate', "Processing client $loginid, created at $creation_stamp, group " . $attributes->{group}, {alert_type => 'info'});

    try {
        my $user          = BOM::User->new((id => $binary_user_id));
        my ($bom_loginid) = $user->bom_real_loginids;
        my ($client)      = grep { $_->loginid eq $bom_loginid } $user->clients;
        if ($client->get_poa_status eq 'verified') {
            BOM::Platform::Event::Emitter::emit(
                'update_loginid_status',
                {
                    binary_user_id => $binary_user_id,
                    loginid        => $loginid,
                    status_code    => undef
                });
            stats_event('StatusUpdate', "$loginid status changed to clear, poa verified", {alert_type => 'info'});
            next;
        }

        if ($attributes->{group} =~ m{bvi}) {
            if ($creation_stamp->days_since_epoch == $bvi_warning_timestamp->days_since_epoch) {

                my $poa_expiry_date = $creation_stamp->plus_time_interval(BVI_EXPIRATION_DAYS . 'd');
                BOM::Platform::Event::Emitter::emit(
                    'poa_verification_warning',
                    {
                        loginid         => $bom_loginid,
                        poa_expiry_date => $poa_expiry_date->date
                    });
                push @clients_warning, "<tr><td>$loginid</td><td>" . $attributes->{group} . "</td></tr>";

            } elsif ($creation_stamp->days_since_epoch < $bvi_expiration_timestamp->days_since_epoch) {

                my @mt5_accounts_under_same_jurisdiction = get_mt5_accounts_under_same_jurisdiction($user, 'bvi');
                stats_event(
                    'StatusUpdate',
                    "Accounts of $bom_loginid under bvi jurisdiction: " . join(' , ', @mt5_accounts_under_same_jurisdiction),
                    {alert_type => 'info'});

                for my $mt5_account (@mt5_accounts_under_same_jurisdiction) {

                    next if $parsed_mt5_account{$mt5_account};
                    BOM::Platform::Event::Emitter::emit(
                        'mt5_change_color',
                        {
                            loginid => $mt5_account,
                            color   => COLOR_RED
                        });

                    BOM::Platform::Event::Emitter::emit(
                        'update_loginid_status',
                        {
                            binary_user_id => $binary_user_id,
                            loginid        => $mt5_account,
                            status_code    => 'poa_failed'
                        });

                    $parsed_mt5_account{$mt5_account} = 1;

                }

                BOM::Platform::Event::Emitter::emit('poa_verification_expired' => {loginid => $bom_loginid});
                push @clients_expired, "<tr><td>$loginid</td><td>" . $attributes->{group} . "</td></tr>";

            }
        } elsif ($attributes->{group} =~ m{vanuatu}) {
            if ($creation_stamp->days_since_epoch == $vanuatu_warning_timestamp->days_since_epoch) {

                my $poa_expiry_date = $creation_stamp->plus_time_interval(VANUATU_EXPIRATION_DAYS . 'd');
                BOM::Platform::Event::Emitter::emit(
                    'poa_verification_warning',
                    {
                        loginid         => $bom_loginid,
                        poa_expiry_date => $poa_expiry_date->date
                    });
                push @clients_warning, "<tr><td>$loginid</td><td>" . $attributes->{group} . "</td></tr>";

            } elsif ($creation_stamp->days_since_epoch < $vanuatu_expiration_timestamp->days_since_epoch) {

                my @mt5_accounts_under_same_jurisdiction = get_mt5_accounts_under_same_jurisdiction($user, 'vanuatu');
                stats_event(
                    'StatusUpdate',
                    "Accounts of $bom_loginid under the vanuatu jurisdiction: " . join(' , ', @mt5_accounts_under_same_jurisdiction),
                    {alert_type => 'info'});

                for my $mt5_account (@mt5_accounts_under_same_jurisdiction) {

                    next if $parsed_mt5_account{$mt5_account};

                    BOM::Platform::Event::Emitter::emit(
                        'mt5_change_color',
                        {
                            loginid => $mt5_account,
                            color   => COLOR_RED
                        });

                    BOM::Platform::Event::Emitter::emit(
                        'update_loginid_status',
                        {
                            binary_user_id => $binary_user_id,
                            loginid        => $mt5_account,
                            status_code    => 'poa_failed'
                        });

                    $parsed_mt5_account{$mt5_account} = 1;
                }

                BOM::Platform::Event::Emitter::emit('poa_verification_expired' => {loginid => $bom_loginid});
                push @clients_expired, "<tr><td>$loginid</td><td>" . $attributes->{group} . "</td></tr>";
            }
        }
    } catch ($e) {
        stats_event('StatusUpdate', "The script ran into an error while processing client $loginid: $e", {alert_type => 'error'});
        push @clients_failed, "<tr><td>$loginid</td><td>" . $attributes->{group} . "</td></tr>";
    }

    $parsed_binary_user_id{$binary_user_id} = 1;
}

my @lines;

if (scalar(@clients_warning)) {
    push @lines, "<p>MT5 clients POA pending status warning email:<p>", '<table border=1>';
    push @lines, '<tr><th>Loginid</th><th>Group</th></tr>';
    push(@lines, @clients_warning);
    push @lines, '</table>';
    stats_event('StatusUpdate', 'Sent ' . scalar(@clients_warning) . ' warning emails.', {alert_type => 'info'});
}

if (scalar(@clients_expired)) {
    push @lines, "<p>MT5 clients POA pending status expiration email:<p>", '<table border=1>';
    push @lines, '<tr><th>Loginid</th><th>Group</th></tr>';
    push(@lines, @clients_expired);
    push @lines, '</table>';
    stats_event('StatusUpdate', 'Sent ' . scalar(@clients_expired) . ' expiration emails.', {alert_type => 'info'});
}

if (scalar(@clients_failed)) {
    push @lines, "<p>MT5 clients POA pending status failed to sent email:<p>", '<table border=1>';
    push @lines, '<tr><th>Loginid</th><th>Group</th></tr>';
    push(@lines, @clients_failed);
    push @lines, '</table>';
    stats_event('StatusUpdate', 'Failed to process ' . scalar(@clients_expired) . ' clients.', {alert_type => 'error'});
}

if (scalar(@lines)) {
    my $brand = Brands->new();
    BOM::Platform::Event::Emitter::emit(
        'send_email',
        {
            from                  => $brand->emails('system'),
            to                    => $brand->emails('cs'),
            subject               => 'CRON update_mt5_trading_rights_and_status: Report for ' . $now->date,
            email_content_is_html => 1,
            message               => \@lines,
        });
}
