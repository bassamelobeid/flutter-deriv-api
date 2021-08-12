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
use BOM::User::Client::AuthenticationDocuments;

# Redis key for resubmission counter
use constant ONFIDO_RESUBMISSION_COUNTER_KEY_PREFIX => 'ONFIDO::RESUBMISSION_COUNTER::ID::';
use constant ONFIDO_REQUEST_PER_USER_PREFIX         => 'ONFIDO::REQUEST::PER::USER::';

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
            client_authentication  => BOM::User::Client::AuthenticationDocuments->get_authentication_definition($client_authentication) // '',
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
        die "MT5/DerivX login IDs are not allowed.\n" if $loginid =~ m/^(MT|DX)[DR]?(\d+$)/;
        my $client = BOM::User::Client->new({loginid => $loginid});
        die "Getting client object failed. Please check if login ID is correct or client exist.\n" unless $client;
        die "Virtual login IDs are not allowed.\n" if $client->is_virtual;
        die "Can not find the associated user. Please check if login ID is correct.\n" unless $client->user;

        my $redis = BOM::Config::Redis::redis_replicated_write();

        my $poi_status_reason = $poi_reason // $client->status->reason('allow_poi_resubmission') // 'unselected';

        # Active client specific update details:
        if ($client_authentication) {
            $client->set_authentication_and_status($client_authentication, $staff);
        }

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
            die "Cannot change POI status on disabled account.However, the authentication status can be changed.\n" if $client->status->disabled;
        } else {    # resubmission is unchecked
            $client->propagate_clear_status('allow_poi_resubmission');
            if (BOM::User::Onfido::submissions_left($client) == 1) {
                BOM::Config::Redis::redis_events()->incrby(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, 1);
            }
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
