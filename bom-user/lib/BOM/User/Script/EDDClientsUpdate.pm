package BOM::User::Script::EDDClientsUpdate;

use strict;
use warnings;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Config;
use BOM::Platform::Email   qw(send_email);
use BOM::Platform::Context qw(request);
use BOM::Platform::Event::Emitter;
use Syntax::Keyword::Try;
use Log::Any qw($log);
use Date::Utility;

use constant ONE_YEAR_INTERVAL => 365;

=head1 NAME

BOM::User::Script::EDDClientsUpdate - Set of functions related to the EDD Client script.

=head1 SYNOPSIS

    my %args = (landing_companies => ['CR','MF']);
    BOM::User::Script::EDDClientsUpdate->new(%args)->run;

=head1 DESCRIPTION

This module is used by `weekly_edd_update_client_update.pl` script.

=cut

=head2 new

Creates a new inscance of the class.

=cut

sub new {
    my ($self, %args) = @_;
    unless ($args{landing_companies}) {
        return undef;
    }
    return bless \%args, $self;
}

=head2 run

Runs the script for the desired broker code.

=cut

sub run {
    my $self       = shift;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->check_for_update();
    my $EDD_auto_lock = $app_config->compliance->enhanced_due_diligence->auto_lock;
    if ($EDD_auto_lock) {
        foreach my $landing_company (@{$self->{landing_companies}}) {
            my $result = $self->_update_EDD_clients_status($landing_company);
            $self->send_mail_to_complaince($landing_company, $result) if @$result;
        }
    } else {
        $log->info('EDD auto_lock feature flag is turned off. Script will be skipped.');
    }

}

=head2 _update_EDD_clients_status

Update list of clients who have deposited more than 20K within the last 365 days.
Clients with EDD status of n/a will be set to pending and allow_document_upload will be set
Client with EDD pending and are more than 7 day will get unwelcome status

=over 4

=item C<landing_company> string

=back

Returns ref of array of hashes with key login_id

=cut

sub _update_EDD_clients_status {
    my ($self, $landing_company) = @_;
    my $connection_builder = BOM::Database::ClientDB->new({
        broker_code => $landing_company,
        operation   => 'replica',
    });
    my $current_date             = Date::Utility->today();
    my $clientdb                 = $connection_builder->db->dbic;
    my $threshold                = BOM::Config::Runtime->instance->app_config->compliance->enhanced_due_diligence->auto_lock_threshold;
    my $high_deposit_EDD_clients = $self->_get_recent_EDD_clients($clientdb, $threshold, $current_date->date_yyyymmdd);
    my @pending_clients;
    foreach my $client_info (@$high_deposit_EDD_clients) {

        try {
            my $client = BOM::User::Client->new({loginid => $client_info->{loginid}});
            my $user   = $client->user;
            next unless $client;
            if (!$client_info->{status} || ($client_info->{status} eq 'n/a')) {
                $client->status->upsert('allow_document_upload', 'system', 'Pending EDD docs/info');
                $user->update_edd_status(
                    status           => 'contacted',
                    start_date       => $client_info->{start_date} || $current_date->date_yyyymmdd,
                    last_review_date => $current_date->date_yyyymmdd,
                    comment          => 'client deposited over 20k in cards',
                    reason           => 'card_deposit_monitoring'
                );
                $self->send_mail_to_client($client, $current_date);
                next;
            }
            if ($client_info->{status} && ($client_info->{status} eq 'contacted') && ($client_info->{reason} eq 'card_deposit_monitoring')) {
                # check if client have been updated more than 7 days ago
                my $last_review_date = Date::Utility->new($client_info->{last_review_date});
                next if $last_review_date->is_after($current_date->minus_time_interval('6d'));

                # check do not update if client is already set to unwelcome
                next if $client->status->unwelcome;

                $client->status->setnx('unwelcome', 'system', 'Pending EDD docs/info - [Compliance] : ** card deposit monitoring.**');
                $client->status->upsert('allow_document_upload', 'system', 'Pending EDD docs/info');
                $user->update_edd_status(
                    status           => 'pending',
                    start_date       => $client_info->{start_date} || $current_date->date_yyyymmdd,
                    last_review_date => $current_date->date_yyyymmdd,
                    comment          => 'client deposited over 20k in cards',
                    reason           => 'card_deposit_monitoring'
                );

                push(@pending_clients, {login_id => $client_info->{loginid}});
            }
        } catch ($e) {
            $log->errorf("An error occurred while processing client %s EDD status: %s", $client_info->{loginid}, $e);
        }
    }
    return \@pending_clients;
}

=head2 _get_recent_EDD_clients

Fetches the list of clients  who have deposited more than 20K within the last 365 days.

=cut

sub _get_recent_EDD_clients {
    my ($self, $clientdb, $threshold, $time) = @_;
    return $clientdb->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT * FROM payment.get_high_deposit_EDD_clients(?,?,?);', {Slice => {}}, $threshold, ONE_YEAR_INTERVAL, $time);
        });
}

=head2 send_mail_to_complaince

sends an email to respective department per landing company

=over 4

=item C<landing_company> string

=item C<EDD_updated_clients> array by hashes

=back

Returns result of BOM::Platform::Email::send_email.

=cut

sub send_mail_to_complaince {
    my ($self, $landing_company, $EDD_updated_clients) = @_;

    $log->debugf('Attempting to send summary email for %s', $landing_company);
    try {
        my @lines = (
            '<tr>',
            '<td bgcolor="#ffffff" align="left" style="padding: 40px 30px 10px 30px;" class="mobile-lowsidepadding darkmodelowblack">',
            '<h2>Following clients are set Unwelcome login & allow_document_upload because of pending  SoF/SoW documents.<br/><br/></h2>',
            '<table border="1"><tr><th>Client-DB</th></tr><tr><td>',
            $landing_company,
            '</td></tr></table><br/><br/><table border="1"><tr><th>operation</th><th>corresponding loginIDs / accounts</th></tr>'
        );
        foreach my $clients (@$EDD_updated_clients) {
            push @lines, sprintf('<tr><td>Unwelcome login</td><td>%s</td></tr>', $clients->{login_id});
        }
        push @lines, '</table></td></tr>';

        my $brand = request()->brand;

        return send_email({
            from                  => $brand->emails('no-reply'),
            to                    => $brand->emails('compliance_ops'),
            subject               => "CompOps - Card Transaction Monitoring ($landing_company)",
            email_content_is_html => 1,
            message               => \@lines
        });
    } catch ($e) {
        $log->errorf('Error sending mail for %s: %s', $landing_company, $e);
        return $e;
    }
}

=head2 send_mail_to_client

trigger event to send email to client

=over 4

=item C<client> client object

=item C<current_date> current date

=back

Returns undef.

=cut

sub send_mail_to_client {
    my ($self, $client, $current_date) = @_;
    my $brand       = request()->brand;
    my $source      = $client->source // '16929';
    my $login_url   = 'https://oauth.' . lc($brand->website_name) . '/oauth2/authorize?app_id=' . $source . '&brand=' . $brand->name;
    my $expiry_date = $current_date->plus_time_interval('7d')->date_yyyymmdd;
    BOM::Platform::Event::Emitter::emit(
        'request_edd_document_upload',
        {
            loginid    => $client->loginid,
            properties => {
                first_name    => $client->first_name,
                email         => $client->email,
                login_url     => $login_url            // '',
                expiry_date   => $expiry_date          // '',
                live_chat_url => $brand->live_chat_url // '',
                language      => $client->user->preferred_language
            }});
    return undef;
}

1;
