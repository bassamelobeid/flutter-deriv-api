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
use BOM::Platform::Token::API;
use BOM::Platform::Context;
use BOM::Event::Utility qw(exception_logged);

#load Brands object globally,
my $BRANDS = BOM::Platform::Context::request()->brand();

=head2 start

removal of a client's personally identifiable information from Binary's systems.
Skip C<MT5> account untouched because we dont want to anonymize third parties yet.
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

Returns **1** on success.
Returns **undef** on failure and sends an email which contains error message to the compliance team.

=cut

# TODO:As of now we anonymize all accounts for a userid but different landing companies may end up with different requirements.
# As an example we might want to anonymize MF but not CR.
# in that case we should queuing multiple events and in the backoffice we select which client records to anonymize.
sub anonymize_client {
    my $data    = shift;
    my $loginid = $data->{loginid};
    my ($user, @clients_hashref);
    return undef unless $loginid;

    try {
        my $client = BOM::User::Client->new({loginid => $loginid});
        $user = $client->user;

        unless ($user->valid_to_anonymize) {
            my $message = sprintf("The user id:%d you're trying to anonymize has at least one active client, and should not anonymize", $user->id);
            $log->debugf($message);
            _send_report_anonymization_failed($client->loginid, $message);

            return undef;
        }

        @clients_hashref = $client->anonymize_associated_user_return_list_of_siblings();
        unless (@clients_hashref) {
            $log->debugf("Anonymize client, getting user failed for %s", $loginid);
            _send_report_anonymization_failed($loginid, "Can not find the associated user. Please check if loginid is correct.",);
            return undef;
        }
        # Anonymize data for all the user's clients
        foreach my $cli (@clients_hashref) {
            $client = BOM::User::Client->new({loginid => $cli->{v_loginid}});
            unless ($client) {
                $log->debugf("Anonymize client getting client object failed for %s", $cli->{v_loginid});
                _send_report_anonymization_failed($cli->{v_loginid}, "Can not find client. Please check if loginid is correct.");
                next;
            }
            # Skip mt5 because we dont want to anonymize third parties yet
            next if $client->is_mt5;
            # Delete documents from S3 because after anonymization the filename will be changed.
            $client->remove_client_authentication_docs_from_S3();
            # Remove Experian reports if any
            if ($client->residence eq 'gb') {
                my $prove = BOM::Platform::ProveID->new(
                    client        => $client,
                    search_option => 'ProveID_KYC'
                );
                BOM::Platform::ProveID->new(client => $client)->delete_existing_reports()
                    if ($prove->has_saved_xml || ($client->status->proveid_requested && !$client->status->proveid_pending));
            }

            # Set client status to disabled to prevent user from doing any future actions
            $client->status->set('disabled', 'system', 'Anonymized client');

            # Remove all user tokens
            my $token = BOM::Platform::Token::API->new;
            $token->remove_by_loginid($client->loginid);

            $client->anonymize_client();
            $log->infof('Anonymize data for user %d and loginid %s.', $cli->{v_buid}, $cli->{v_loginid});
        }
    }
    catch {
        $log->debugf('Anonymize client failed %s.', $@);
        exception_logged();
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
