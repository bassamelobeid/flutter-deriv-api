package BOM::Event::Actions::Anonymization;

use strict;
use warnings;
use Log::Any qw($log);
use BOM::User;
use BOM::User::Client;
use BOM::Platform::ProveID;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use Syntax::Keyword::Try;
use BOM::Platform::Context;
use BOM::Platform::S3Client;

#load Brands object globally,
my $BRANDS = BOM::Platform::Context::request()->brand();

=head2 start

removal of a client's personally identifiable information from Binary's systems.
This module will anonymize below information :
- replace these with `deleted`
   - first and last names (deleted+loginid)
   - address 1 and 2 (including town/city and postcode)
   - TID (Tax Identification number)
   - secret question and answers (not mandatory)
- replace email address with `loginid@deleted.binary.user (e.g.mx11161@deleted.binary.user). Only lowercase shall be used.
- replace telephone number with empty string ( only empty string will pass phone number validation, fake valid number might be a real number! )
- all personal data available in the audit trail (history of changes) in BO
- IP address in login history in BO
- payment remarks for bank wires transactions available on the client's account statement in BO should be `deleted wire payment`
- documents (delete)

=over 4

=item * C<loginid> - login id of client to trigger anonymization on

=back

=cut

# TODO:As of now we anonymize all accounts for a userid but different landing companies may end up with different requirements.
# As an example we might want to anonymize MF but not CR.
# in that case we should queuing muiltiple events and in the backoffice we select which client records to anonymise.
sub anonymize_client {
    my $data    = shift;
    my $loginid = $data->{loginid};
    return undef unless $loginid;

    try {
        my $dbic = BOM::Database::UserDB::rose_db()->dbic;
        # Get list of loginids for a userid
        my @buid = $dbic->run(
            fixup => sub {
                $_->selectall_arrayref("SELECT * FROM users.user_anonymization(?)", {Slice => {}}, $loginid);
            })->@*;

        unless (@buid) {
            $log->warnf("Anonymize client , getting user failed for %s", $loginid);
            _send_report_anonymization_failed($loginid, "Can not find user. Please check if loginid is correct.",);
            return undef;
        }
        # Anonymize data for all clients;
        foreach my $cli (@buid) {
            # Skip mt5 because we dont want to anonymize third parties yet
            next if $cli->{v_loginid} =~ /^MT/;
            my $client = BOM::User::Client->new({loginid => $cli->{v_loginid}});
            unless ($client) {
                $log->warnf("Anonymize client getting client object failed for %s", $cli->{v_loginid});
                _send_report_anonymization_failed($cli->{v_loginid}, "Can not find client. Please check if loginid is correct.");
                next;
            }
            # Delete documents from S3 because after anonymization the filename will be changed.
            my $docs = $client->db->dbic->run(
                fixup => sub {
                    $_->selectall_arrayref(<<'SQL', undef, $loginid);
SELECT file_name
  FROM betonmarkets.client_authentication_document
 WHERE client_loginid = ? AND status != 'uploading'
SQL
                });
            if ($docs) {
                my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
                foreach my $doc (@$docs) {
                    my $filename = $doc->[0];
                    $s3_client->delete($filename);
                }
            }
            # Remove Experian reports if any
            if ($client->residence eq 'gb') {
                my $prove = BOM::Platform::ProveID->new(
                    client        => $client,
                    search_option => 'ProveID_KYC'
                );
                BOM::Platform::ProveID->new(client => $client)->delete_existing_reports()
                    if ($prove->has_saved_xml || ($client->status->proveid_requested && !$client->status->proveid_pending));
            }
            $client->db->dbic->run(
                fixup => sub {
                    $_->do('SELECT * FROM betonmarkets.client_anonymization(?)', undef, $cli->{v_loginid});
                });
            $log->infof('Anonymize data for user %s and loginid %s.', $cli->{v_buid}, $cli->{v_loginid});
        }
    }
    catch {
        $log->warnf('Anonymize client failed %s.', $@);
        _send_report_anonymization_failed($loginid, "Client anonymization failed. Please re-try or inform Backend team.");
        return undef;
    };

    return 1;
}

=head2 _send_report_anonymization_failed

Send email to Compliance because of which we were not able to anonymize client

=cut

sub _send_report_anonymization_failed {
    my ($loginid, $failure_reason) = @_;

    my $email_subject = "Anonymization failed for $loginid";

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('compliance');
    my $email_status =
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)
        ->text_body("We were unable to anonymize client ($loginid), $failure_reason")->send();

    $log->warn('failed to send anonymization failure email.') unless $email_status;
    return undef;
}

1;
