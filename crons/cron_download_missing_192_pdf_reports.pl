#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Path::Tiny;
use Try::Tiny;

use BOM::Platform::ProveID;
use BOM::Platform::Runtime;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Client;

my $accounts_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_accounts";
my $so = 'ProveID_KYC';    # At the time of writing this script this is the only search option we have

for my $broker (qw/MF MX/) {
    my $pending_loginids = find_loginids_with_pending_experian($broker);

    for my $loginid (@$pending_loginids) {
        my $xml_exists = -e get_filename(
            broker  => $broker,
            loginid => $loginid,
            type    => 'xml'
        );
        my $pdf_exists = -e get_filename(
            broker  => $broker,
            loginid => $loginid,
            type    => 'pdf'
        );

        try {
            if (not $xml_exists) {
                request_proveid($loginid);
            } elsif (not $pdf_exists) {
                request_pdf($broker, $loginid);
            } else {
                remove_pending_status($loginid);
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
WHERE status_code = 'proveid_pending' AND last_modified_date >= NOW() - INTERVAL '2 hour';
SQL

    return [grep { $_ =~ /$broker/ } map { $_->{client_loginid} } @$result];
}

sub get_filename {
    my %args = @_;
    my ($broker, $loginid, $type) = @args{qw/broker loginid type/};

    my $extension = $type eq 'pdf' ? '.pdf' : '';

    return "$accounts_dir/$broker/192com_authentication/$type/$loginid.$so$extension";
}

sub request_pdf {
    my ($broker, $loginid) = @_;

    my $result_as_xml = path(
        get_filename(
            broker  => $broker,
            loginid => $loginid,
            type    => 'xml'
        ))->slurp_utf8;

    my $client = get_client($loginid);

    try {
        BOM::Platform::ProveID->new(
            client        => $client,
            result_as_xml => $result_as_xml,
            search_option => $so
            )->save_pdf_result
    }
    catch {
        die "Failed to save Experian pdf for " . $client->loginid . ": $_";
    };

    return remove_pending_status($loginid);
}

sub request_proveid {
    my ($loginid) = @_;

    my $client = get_client($loginid);

    BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    )->_do_proveid;

    # Remove pending status to prevent ProveID search for the next cron schedule
    return remove_pending_status($loginid);
}

sub remove_pending_status {
    my $loginid = shift;

    my $client = get_client($loginid);

    $client->clr_status('proveid_pending');
    return $client->save or die 'Unable to clear proveid_pending status';
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
