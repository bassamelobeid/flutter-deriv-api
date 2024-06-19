package BOM::User::Script::IDVLookbackFix;

use strict;
use warnings;
no indirect;

use constant LIMIT       => 100;
use constant FIRST_PIVOT => 0;
use Log::Any qw($log);
use BOM::User;
use JSON::MaybeUTF8 qw(decode_json_text);

=head1 NAME

BOM::User::Script::IDVLookbackFix - Recover the age verification from IDV clients.

=head1 SYNOPSIS

    BOM::User::Script::IDVLookbackFix::run;

=head1 DESCRIPTION

This module is used by the `idv_lookback_fix.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run once to bring age verification status back to those clients who were wrongly shaken out.

=cut

use BOM::Database::ClientDB;
use BOM::Database::UserDB;

=head2 run

Grabs candidate users from the IDV tables.

Checks through the CR audit status table to determine whether the client have gone through the lookback incorrectly and insert/update the missing data accordingly.

It can take:

=over 4

=item * <$limit> - an optional parameter to establish the limit used at the pagination.

=back

Returns C<undef>

=cut

sub run {
    my ($limit) = @_;

    # DOB_MISMATCH and NAME_MISMATCH are candidates for the wrongly updated checks
    # Currently on database roughly ~1000 registers are affected
    # Start with a pivot of 0 to paginate through

    my $effective_limit = $limit // LIMIT;
    my $checks          = candidates(['DOB_MISMATCH', 'NAME_MISMATCH'], $effective_limit, FIRST_PIVOT);
    my $counter         = 0;
    my $recovered       = 0;
    my $false_positives = 0;

    while (scalar $checks->@*) {
        my $pivot;

        for my $check ($checks->@*) {
            $pivot = $check->{id};
            $counter++;

            if (recover(@{$check}{qw/id binary_user_id/})) {
                $log->infof("Recovered a check for %d", $check->{binary_user_id});
                $recovered++;
            } else {
                $log->infof("False positive check for %d", $check->{binary_user_id});
                $false_positives++;
            }
        }

        last unless $pivot;

        last unless scalar $checks->@* >= $effective_limit;

        $checks = candidates(['DOB_MISMATCH', 'NAME_MISMATCH'], $effective_limit, $pivot);
    }

    $log->infof("Processed: %d",       $counter);
    $log->infof("Recovered: %d",       $recovered);
    $log->infof("False positives: %d", $false_positives);

}

=head2 recover

Analyzes the audit table looking for a wrong DELETE on the `age_verification` status.
If found this will give it back and also update the `idv.document` related to the check id.
Note there is a chance the check gotten is a false positive, no action should be taken if so.

It takes the following arguments:

=over 4

=item * C<id> - id of the affected `idv.document_check`

=item * C<binary_user_id> - id of the affected user

=back

Returns a bool scalar determining that the data was recovered.

=cut

sub recover {
    my ($id, $binary_user_id) = @_;

    # The bug is that the event should not be ran upon checks that lacks birthdate or full_name
    # these type of checks come mostly from IDV non data providers like zaig and datazoo,but other providers can also produce incomplete reports.

    my $user = BOM::User->new(id => $binary_user_id);

    if ($user) {
        # IDV only applies to svg
        my ($client) = grep { $_->landing_company->short eq 'svg' } $user->clients;

        if ($client) {
            my $dbic = BOM::Database::ClientDB->new({
                    client_loginid => $client->loginid,
                    operation      => 'replica',
                })->db->dbic;

            my ($status_delete) = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref(
                        'SELECT reason FROM audit.client_status WHERE client_loginid = ? AND operation = ? AND status_code = ? ORDER BY stamp ASC LIMIT 1',
                        {Slice => {}}, $client->loginid, 'DELETE', 'age_verification'
                    );
                })->@*;

            if ($status_delete) {
                my ($provider) = $status_delete->{reason} =~ /^(.*?) - age verified/;

                if ($provider && lc($provider) ne 'onfido') {
                    my $idv_model = BOM::User::IdentityVerification->new(user_id => $user->id);
                    my $document  = $idv_model->get_last_updated_document();

                    if ($document) {
                        my $messages =
                            [grep { $_ ne 'DOB_MISMATCH' && $_ ne 'NAME_MISMATCH' } decode_json_text($document->{status_messages} // '[]')->@*];

                        # attempt to give the status back
                        $client->status->setnx('age_verification', 'system', "$provider - age verified");
                        # remove name mismatch
                        $client->propagate_clear_status('poi_name_mismatch');
                        # remove dob mismatch
                        $client->propagate_clear_status('poi_dob_mismatch');
                        # make the IDV document verified
                        $idv_model->update_document_check({
                            document_id => $document->{id},
                            status      => 'verified',
                            messages    => $messages,
                            provider    => $provider,
                        });

                        return 1;

                    }
                }
            }
        }
    }

    return 0;
}

=head2 candidates

Grab candidates binary_user_id to check through the CR audit tables later on.

Returns an arrayref of hashes containing:

=over 4 

=item * C<id> - id of the affected `idv.document_check`

=item * C<binary_user_id> - id of the affected user

=back

=cut

sub candidates {
    my ($messages, $limit, $pivot) = @_;

    my $userdb = BOM::Database::UserDB::rose_db(operation => 'replica');

    return $userdb->dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT id, binary_user_id FROM idv.get_empty_reports(?, ?, ?)', {Slice => {}}, $messages, $limit, $pivot);
        });
}

1;
