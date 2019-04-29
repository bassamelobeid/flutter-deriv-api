#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Path::Tiny;
use Try::Tiny;

use BOM::Platform::ProveID;
use BOM::Config::Runtime;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Client;

my $accounts_dir = BOM::Config::Runtime->instance->app_config->system->directory->db . "/f_accounts";
my $so = 'ProveID_KYC';    # At the time of writing this script this is the only search option we have

for my $broker (qw/MF MX/) {
    my $pending_loginids = find_loginids_with_pending_experian($broker);

    for my $loginid (@$pending_loginids) {
        my $client  = get_client($loginid);
        my $proveid = BOM::Platform::ProveID->new(
            client        => $client,
            search_option => $so
        );
        my $xml_exists = $proveid->has_saved_xml;
        my $pdf_exists = $proveid->has_saved_pdf;

        try {
            my $client = get_client($loginid);
            unless ($xml_exists) {
                request_proveid($client);
            }
            $client->status->clear_proveid_pending;
            my $unwelcome = $client->status->unwelcome;
            $client->status->clear_unwelcome if $unwelcome and $unwelcome->{reason} =~ /^FailedExperian/;
            if ($xml_exists and not $pdf_exists) {
                request_pdf($broker, $client);
            }
        }
        catch {
            warn "ProveID failed, $_";
        };
    }
}

##########################
# Helper functions       #
##########################

sub get_db_for_broker {
    return BOM::Database::ClientDB->new({
            broker_code => shift,
            operation   => 'replica',
        })->db;
}

sub find_loginids_with_pending_experian {
    my $broker = shift;
    my $dbic   = get_db_for_broker($broker)->dbic;

    my $result = $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(<<'SQL', {Slice => {}}) });
SELECT client_loginid FROM betonmarkets.client_status
WHERE status_code = 'proveid_pending' AND last_modified_date >= NOW() - INTERVAL '1 hour';
SQL

    return [grep { $_ =~ /$broker/ } map { $_->{client_loginid} } @$result];
}

sub request_pdf {
    my ($broker, $client) = @_;

    try {
        BOM::Platform::ProveID->new(
            client        => $client,
            search_option => $so
        )->get_pdf_result;
    }
    catch {
        die "Failed to save Experian pdf for " . $client->loginid . ": $_";
    };
    return;
}

sub request_proveid {
    my ($client) = @_;

    return BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    )->proveid;
}

sub get_client {
    my $loginid = shift;

    return try {
        BOM::User::Client->new({
            loginid      => $loginid,
            db_operation => 'replica'
        });
    }
    catch {
        die "Error: can't identify client $loginid: $_";
    };
}
