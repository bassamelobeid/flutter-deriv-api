package BOM::Event::Actions::Authentication;

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
use BOM::Platform::Email qw(send_email);

# Redis key for resubmission counter
use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
use constant ONFIDO_REQUEST_PER_USER_PREFIX         => 'ONFIDO::REQUEST::PER::USER::';

## NOTICE : THESE TWO CONSTANTS COULD BE MOVED, POTENTIAL DUPLICATE
use constant AUTHENTICATION_DEFINITION => {
    'CLEAR_ALL'    => 'Not authenticated',
    'ID_DOCUMENT'  => 'Authenticated with scans',
    'ID_NOTARIZED' => 'Authenticated with Notarized docs',
    'ID_ONLINE'    => 'Authenticated with online verification',
    'NEEDS_ACTION' => 'Needs Action',
};

use constant POI_DEFINITION => {
    'blurred'               => 'Blurred',
    'cropped'               => 'Cropped',
    'different_person_name' => 'Different person/name',
    'expired'               => 'Expired',
    'missing_one_side'      => 'Missing one side',
    'nimc_no_dob'           => 'Nimc or no dob',
    'selfie_is_not_valid'   => 'selfie is not valid',
    'suspicious'            => 'Suspicious',
    'type_is_not_valid'     => 'Type is not valid',
    'other'                 => 'Other',
};

=head1 METHODS

=head2 bulk_authentication

Bulk authentication for a list of client's accounts by changing POI-resubmission and authentication status.

=over 4

=item * C<args> - A hash including data to trigger authentication.

=back

Returns B<1> on success.

=cut

sub bulk_authentication {
    my $args                   = shift;
    my $data                   = $args->{data};
    my $client_authentication  = $args->{client_authentication};
    my $allow_poi_resubmission = $args->{allow_poi_resubmission};
    my $poi_reason             = $args->{poi_reason};
    my $staff                  = $args->{staff};
    my $to_email               = $args->{to_email};
    my $staff_department       = $args->{staff_department};
    my $comment                = $args->{comment};
    my $staff_ip               = $args->{staff_ip};

    die "csv input file should exist"                                  unless $data;
    die "client_authentication or allow_poi_resubmission should exist" unless $client_authentication || $allow_poi_resubmission;
    die "email to send results does not exist"                         unless $to_email;

    my ($success, $error);

    my @loginids = uniqstr grep { $_ } map { uc(Text::Trim::trim($_)) } map { $_->@* } $data->@*;
    foreach my $loginid (@loginids) {
        my $result = _authentication($loginid, $client_authentication, $allow_poi_resubmission, $poi_reason, $staff, $staff_ip);
        $result eq "1" ? $success->{$loginid} = "Successful" : ($error->{$loginid} = $result);
    }
    _send_authentication_report($error, $success, $client_authentication, $allow_poi_resubmission, $poi_reason, $to_email, $staff_department,
        $comment);
    return 1;
}

=head2 _send_authentication_report

Send email to Compliance because of which clients we were not able to trigger authentication

=over 4

=item * C<failures> - A hash of loginids with failure reason

=item * C<successes> - A hash of loginids with successful result

=item * C<client_authentication> - Client authentication value

=item * C<allow_poi_resubmission> - Boolean, allow poi resubmission or not

=item * C<poi_reason> - poi reason value

=item * C<to_email> - Email provided in the backoffice to send email to

=item * C<staff_department> - Department provided in the backoffice to send email to

=item * C<comment> - comment 


=back

return B<undef>

=cut

sub _send_authentication_report {
    my ($failures, $successes, $client_authentication, $allow_poi_resubmission, $poi_reason, $to_email, $staff_department, $comment) = @_;

    my $email_subject = "Authentication report for " . Date::Utility->new->date;
    my $from_email    = 'no-reply@deriv.com';

    my $report = {
        title      => "Authentication Report",
        comment    => $comment,
        successes  => $successes,
        failures   => $failures,
        auth_param => {
            client_authentication  => AUTHENTICATION_DEFINITION->{$client_authentication} // '',
            allow_poi_resubmission => $allow_poi_resubmission,
            poi_reason             => POI_DEFINITION->{$poi_reason} // '',
        }};

    my $brands = BOM::Platform::Context::request()->brand();
    send_email({
        from                  => $from_email,
        to                    => $brands->emails(lc $staff_department),
        subject               => $email_subject,
        template_name         => 'authentication_report',
        template_args         => $report,
        email_content_is_html => 1,
        use_email_template    => 1,
    });

    my $email_status = send_email({
        from                  => $from_email,
        to                    => $to_email,
        subject               => $email_subject,
        template_name         => 'authentication_report',
        template_args         => $report,
        email_content_is_html => 1,
        use_email_template    => 1,
    });

    unless ($email_status) {
        $log->error("Sending authentication report email from $from_email to $to_email subject $email_subject has failed");
    }

    return undef;
}

=head2 _authentication

## NOTICE : THIS FUNTION COULD BE MOVED, POTENTIAL DUPLICATE

=over 4

=item * C<loginid> - login id of client to trigger authentication

=item * C<client_authentication> - client authentication status

=item * C<allow_poi_resubmission> - boolean that show if poi resubmission is allowed

=item * C<poi_reason> - reason for poi

=item * C<staff> - the staff who triggered the process

=back

Returns 1 on success.
Returns error_code on failure.

Possible error_codes for now are:

=cut

sub _authentication {
    my ($loginid, $client_authentication, $allow_poi_resubmission, $poi_reason, $staff, $staff_ip) = @_;

    local @ENV{qw(AUDIT_STAFF_NAME AUDIT_STAFF_IP)} = ($staff, $staff_ip);

    try {
        my $client = BOM::User::Client->new({loginid => $loginid});
        die "Getting client object failed. Please check if login ID is correct or client exist.\n" unless $client;
        die "Can not find the associated user. Please check if login ID is correct.\n"             unless $client->user;

        my $redis = BOM::Config::Redis::redis_replicated_write();

        my $poi_status_reason = $poi_reason // $client->status->reason('allow_poi_resubmission') // 'unselected';

        # POI resubmission logic
        if ($allow_poi_resubmission) {
            #this also allows the client only 1 time to resubmit the documents
            if (   !$client->status->reason('allow_poi_resubmission')
                && BOM::User::Onfido::submissions_left($client) == 0
                && !$redis->get(ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX . $client->binary_user_id))
            {
                BOM::Config::Redis::redis_events()->incrby(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, -1);
            }
            $client->propagate_status('allow_poi_resubmission', $staff, $poi_status_reason);
        } else {    # resubmission is unchecked
            $client->propagate_clear_status('allow_poi_resubmission');
            if (BOM::User::Onfido::submissions_left($client) == 1) {

                BOM::Config::Redis::redis_events()->incrby(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, 1);
            }
        }

        # Active client specific update details:
        if ($client_authentication) {
            # Remove existing status to make the auth methods mutually exclusive
            $_->delete for @{$client->client_authentication_method};

            if ($client_authentication eq 'ID_NOTARIZED') {
                $client->set_authentication('ID_NOTARIZED', {status => 'pass'}, $staff);
            }

            my $already_passed_id_document =
                  $client->get_authentication('ID_DOCUMENT')
                ? $client->get_authentication('ID_DOCUMENT')->status
                : '';
            if ($client_authentication eq 'ID_DOCUMENT'
                && !($already_passed_id_document eq 'pass'))
            {    #Authenticated with scans, front end lets this get run again even if already set.

                $client->set_authentication('ID_DOCUMENT', {status => 'pass'}, $staff);
                BOM::Platform::Event::Emitter::emit('authenticated_with_scans', {loginid => $loginid});
            }

            my $already_passed_id_online =
                  $client->get_authentication('ID_ONLINE')
                ? $client->get_authentication('ID_ONLINE')->status
                : '';
            if (   $client_authentication eq 'ID_ONLINE'
                && $already_passed_id_online ne 'pass')
            {
                $client->set_authentication('ID_ONLINE', {status => 'pass'}, $staff);
            }

            if ($client_authentication eq 'NEEDS_ACTION') {
                $client->set_authentication('ID_DOCUMENT', {status => 'needs_action'}, $staff);
                # 'Needs Action' shouldn't replace the locks from the account because we'll lose the request authentication reason
                $client->status->upsert('allow_document_upload', $staff, 'MARKED_AS_NEEDS_ACTION');
            }

            $client->save;
            $client->update_status_after_auth_fa('', $staff);
            # Remove unwelcome status from MX client once it fully authenticated
            $client->status->clear_unwelcome
                if ($client->residence eq 'gb'
                and $client->landing_company->short eq 'iom'
                and $client->fully_authenticated
                and $client->status->unwelcome);
        }

    } catch ($error) {
        exception_logged();
        chomp($error);
        $log->errorf('Triggerng authentication for %s failed, client_authentication=%s, allow_poi_resubmission=%s, poi_reason=%s, staff=%s,error=%s',
            $loginid, $client_authentication, $allow_poi_resubmission, $poi_reason, $staff, $error);
        $error ? return $error : return "Triggering authentication failed. Please re-try or inform Backend team.";
    }
    return 1;
}

1;
