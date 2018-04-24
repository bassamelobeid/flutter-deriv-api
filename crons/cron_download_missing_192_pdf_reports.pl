#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use Path::Tiny;

use BOM::Platform::ProveID;
use BOM::Platform::Runtime;
use BOM::Platform::Client::IDAuthentication;
use BOM::User::Client;

my $accounts_dir = BOM::Platform::Runtime->instance->app_config->system->directory->db . "/f_accounts";
my $so = 'ProveID_KYC';    # At the time of writing this script this is the only search option we have

for my $broker (qw/MF MX/) {
    my $pending_loginids = find_loginids_with_pending_experian($broker);

    for my $loginid (@$pending_loginids) {
        my ($xml_exists, $pdf_exists) = (-e get_filename($broker, $loginid), -e get_filename($broker, $loginid, 1));

        if ($pdf_exists && $xml_exists) {
            # Files exists but status is not set, set the status and skip
            remove_pending_status($loginid);
            next;
        }

        request_proveid($loginid) unless $xml_exists;

        request_pdf($broker, $loginid) if $xml_exists and not $pdf_exists;
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
    my ($broker, $loginid, $is_pdf) = @_;

    my $extension = $is_pdf ? '.pdf' : '';
    my $type      = $is_pdf ? 'pdf'  : 'xml';

    return "$accounts_dir/$broker/192com_authentication/$type/$loginid.$so$extension";
}

sub request_pdf {
    my ($broker, $loginid) = @_;

    my $result_as_xml = path(get_filename($broker, $loginid))->slurp_utf8;

    my $client = get_client($loginid);

    eval { BOM::Platform::ProveID->new(client => $client, result_as_xml => $result_as_xml, search_option => $so,)->save_pdf_result }
        or die("Failed to save Experian pdf for " . $client->loginid . ": $@");

    remove_pending_status($loginid);
}

sub request_proveid {
    my ($loginid) = @_;

    my $client = get_client($loginid);

    my $id_auth = BOM::Platform::Client::IDAuthentication->new(
        client        => $client,
        force_recheck => 1
    )->_do_proveid;
}

sub remove_pending_status {
    my $loginid = shift;

    my $client = get_client($loginid);

    $client->clr_status('proveid_pending');
    $client->save or die 'Unable to clear proveid_pending status';
}

sub get_client {
    my $loginid = shift;

    return eval { BOM::User::Client->new({loginid => $loginid, db_operation => 'replica'}) }
        or die "Error: can't identify client $loginid: $@";
}
