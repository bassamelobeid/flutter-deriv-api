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
use List::Util qw(uniqstr);
# Load Brands object globally
my $BRANDS = BOM::Platform::Context::request()->brand();

use constant ERROR_MESSAGE_MAPPING => {
    activeClient          => "The user you're trying to anonymize has at least one active client, and should not anonymize",
    userNotFound          => "Can not find the associated user. Please check if loginid is correct.",
    clientNotFound        => "Getting client object failed. Please check if loginid is correct or client exist.",
    anonymizationFailed   => "Client anonymization failed. Please re-try or inform Backend team.",
    userAlreadyAnonymized => "Client is already anonymized",
};

=head2 anonymize_client

Removal of a client's personally identifiable information from Binary's systems.

=over 4

=item * C<arg> - A hash including loginid

=back

Returns B<1> on success.

=cut

sub anonymize_client {
    my $arg     = shift;
    my $loginid = $arg->{loginid};
    return undef unless $loginid;
    my ($success, $error);
    my $result = _anonymize($loginid);
    $result eq 'successful' ? $success->{$loginid} = $result : ($error->{$loginid} = ERROR_MESSAGE_MAPPING->{$result});
    _send_anonymization_report($error, $success);
    return 1;
}

=head2 bulk_anonymization

Remove client's personally identifiable information (PII)

=over 1

=item * C<arg> - A hash including data about loginids to be anonymized.

=back

Returns **1** on success.

=cut

sub bulk_anonymization {
    my $arg  = shift;
    my $data = $arg->{data};
    return undef unless $data;
    my ($success, $error);

    my @loginids = uniqstr grep { $_ } map { uc $_ } map { s/^\s+|\s+$//gr } map { $_->@* } $data->@*;
    foreach my $loginid (@loginids) {
        my $result = _anonymize($loginid);
        $result eq 'successful' ? $success->{$loginid} = $result : $error->{$loginid} = ERROR_MESSAGE_MAPPING->{$result};
    }
    _send_anonymization_report($error, $success);
    return 1;
}

=head2 _send_anonymization_report

Send email to Compliance because of which we were not able to anonymize client

=over 3

=item * C<failures> - A hash of loginids with failure reason

=item * C<successes> - A hash of loginids with successfull result

=back

return undef

=cut

sub _send_anonymization_report {
    my ($failures, $successes) = @_;
    my $number_of_failures  = scalar keys %$failures;
    my $number_of_successes = scalar keys %$successes;
    my $email_subject       = "Anonymization report for " . Date::Utility->new->date;

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('compliance');
    my $success_clients;
    $success_clients = join(',', sort keys %$successes) if $number_of_successes > 0;

    my $report = {
        success => {
            number_of_successes => $number_of_successes,
        },
        error => {
            number_of_failures => $number_of_failures,
            failures           => $failures,
        }};

    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/anonymization_report.html.tt', $report, \my $body);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return undef;
    }
    if ($success_clients) {
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($body)->attach(
            $success_clients,
            filename     => 'success_loginids.csv',
            content_type => 'text/plain',
            disposition  => 'attachment',
            charset      => 'UTF-8'
            )->send
            or warn "Sending email from $from_email to $to_email subject $email_subject failed";
    } else {
        Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($body)->send
            or warn "Sending email from $from_email to $to_email subject $email_subject failed";
    }

    return undef;
}

=head2 _anonymize

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

Returns the string B<successful> on success.
Returns error_code on failure.

Possible error_codes for now are:

=over 4

=item * clientNotFound

=item * userAlreadyAnonymized

=item * userNotFound

=item * anonymizationFailed

=item * activeClient

=back

=cut

sub _anonymize {
    my $loginid = shift;
    my ($user, @clients_hashref);
    try {
        my $client = BOM::User::Client->new({loginid => $loginid});
        return "clientNotFound" unless ($client);
        $user = $client->user;
        return "userNotFound" unless $user;
        return "userAlreadyAnonymized" if $user->email =~ /\@deleted\.binary\.user$/;
        return "activeClient" unless ($user->valid_to_anonymize);
        @clients_hashref = $client->user->clients(
            include_disabled   => 1,
            include_duplicated => 1,
        );
        # Anonymize data for all the user's clients
        foreach my $cli (@clients_hashref) {
            # Skip mt5 because we dont want to anonymize third parties yet
            next if $cli->is_mt5;
            # Skip if client already anonymized
            next if $cli->email =~ /\@deleted\.binary\.user$/;
            # Delete documents from S3 because after anonymization the filename will be changed.
            $cli->remove_client_authentication_docs_from_S3();
            # Remove Experian reports if any
            if ($cli->residence eq 'gb') {
                my $prove = BOM::Platform::ProveID->new(
                    client        => $cli,
                    search_option => 'ProveID_KYC'
                );
                BOM::Platform::ProveID->new(client => $cli)->delete_existing_reports()
                    if ($prove->has_saved_xml || ($cli->status->proveid_requested && !$cli->status->proveid_pending));
            }
            # Set client status to disabled to prevent user from doing any future actions

            $cli->status->setnx('disabled', 'system', 'Anonymized client');

            # Remove all user tokens
            my $token = BOM::Platform::Token::API->new;
            $token->remove_by_loginid($cli->loginid);

            $cli->anonymize_client();
        }
        return "userNotFound" unless $client->anonymize_associated_user_return_list_of_siblings();
    } catch ($error) {
        exception_logged();
        $log->errorf('Anonymization failed: %s', $error);
        return "anonymizationFailed";
    }
    return "successful";
}

1;
