package BOM::Event::Actions::Anonymization;

use strict;
use warnings;
use BOM::Config::Runtime;
use Future;
use Future::AsyncAwait;
use List::Util qw( uniqstr );
use Log::Any   qw( $log );
use Syntax::Keyword::Try;
use Time::HiRes;

use BOM::User;
use BOM::User::Client;
use BOM::Platform::Doughflow;
use BOM::Event::Actions::CustomerIO;
use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use BOM::Event::Utility qw( exception_logged );
use BOM::Platform::CloseIO;
use BOM::Platform::Context;
use BOM::Platform::Desk;
use BOM::Platform::Token::API;
use IO::Async::Loop;
use BOM::Event::Services;
use LandingCompany::Registry;
use BOM::Platform::Email qw(send_email);
use BOM::Config::Runtime;
use BOM::OAuth::OneAll;

use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use BOM::Platform::Email       qw(send_email);
use BOM::MT5::User::Async;

# Load Brands object globally
my $BRANDS = BOM::Platform::Context::request()->brand();

use constant ERROR_MESSAGE_MAPPING => {
    activeClient          => "The user you're trying to anonymize has at least one active client, and should not anonymize",
    userNotFound          => "Can not find the associated user. Please check if loginid is correct.",
    clientNotFound        => "Getting client object failed. Please check if loginid is correct or client exist.",
    anonymizationFailed   => "Client anonymization failed. Please re-try or inform Backend team.",
    userAlreadyAnonymized => "Client is already anonymized",
    deskError             => "couldn't anonymize user from s3 desk",
    closeIOError          => "couldn't anonymize user from Close.io",
    oneallError           => "Couldn't anonymize user from Oneall",
    mt5AnonymizationError => "An API error occurred while anonymizing one or more MT5 Accounts"
};

use constant DF_ANONYMIZATION_KEY               => 'DF_ANONYMIZATION_QUEUE';
use constant DF_ANONYMIZATION_RETRY_COUNTER_KEY => 'DF_ANONYMIZATION_RETRY_COUNTER::';
use constant DF_ANONYMIZATION_RETRY_TTL         => 3600;
use constant DF_ANONYMIZATION_MAX_RETRY         => 3;

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

{

    sub _redis_payment_write {
        return $services->redis_payment_write();
    }
}

=head2 MAX_ANONYMIZATION_CHUNCK_SIZE

The maximum number of clients to be anonymized in a single event.

=cut

sub MAX_ANONYMIZATION_CHUNCK_SIZE { return 20; }

=head2 anonymize_client

Removal of a client's personally identifiable information from Binary's systems.

=over 4

=item * C<args> - A hash including loginid

=back

Returns B<1> on success.

=cut

async sub anonymize_client {
    my $args = shift;

    my $loginid = $args->{loginid};
    return undef unless $loginid;

    my ($success, $error);
    my $result = await _anonymize($loginid);
    $result eq 'successful' ? $success->{$loginid} = $result : ($error->{$loginid} = ERROR_MESSAGE_MAPPING->{$result});

    _send_anonymization_report($error, $success);

    return 1;
}

=head2 bulk_anonymization

Remove clients' personally identifiable information (PII) in bulk.

This subroutine acts as a wrapper for the 'anonymize_clients' subroutine.
It takes a large list of login IDs , splits them into smaller chunks, and emits a new event for each chunk.
This is to prevents timeout issues or blocking the worker for long time when handling a large list of clients.


=over 1

=item * C<args> - A hash ref including data about loginids to be anonymized.

=back

Returns 1 on success.

=cut

async sub bulk_anonymization {
    my $args = shift;

    my $loginids_list = $args->{data};
    return undef unless $loginids_list;

    while (@$loginids_list) {
        my @chunk = splice @$loginids_list, 0, MAX_ANONYMIZATION_CHUNCK_SIZE;
        BOM::Platform::Event::Emitter::emit('anonymize_clients', {data => \@chunk});
    }

    return 1;
}

=head2 anonymize_clients

Remove client's personally identifiable information (PII) for a list of clients.

=over 1

=item * C<args> - A hash including data about loginids to be anonymized.

=back

Returns **1** on success.

=cut

async sub anonymize_clients {
    my $args = shift;

    my $data = $args->{data};
    return undef unless $data;

    my ($success, $error);

    my @loginids = uniqstr grep { $_ } map { uc $_ } map { s/^\s+|\s+$//gr } map { (ref $_ eq 'ARRAY') ? ($_->@*) : $_ } $data->@*;
    $error->{'There is no login ID'} = "There was no candidate or file was corrupt" unless scalar @loginids;

    my $start_time = Time::HiRes::time;
    foreach my $loginid (@loginids) {
        my $result = await _anonymize($loginid);

        if ($result eq 'successful') {
            $success->{$loginid} = $result;
        } else {
            $error->{$loginid} = ERROR_MESSAGE_MAPPING->{$result} // $result;
        }
    }

    my $type = $args->{title} // 'Bulk Anonymization';
    stats_timing('anonymization.bulk.duration', Time::HiRes::time - $start_time, {tags => ["type:$type"]});

    _send_anonymization_report($error, $success, $args->{title});
    return 1;
}

=head2 auto_anonymize_candidates

Anonymizes the clients identified as anonymization candidates and approved by the compliance team.
This event is emitted by the auto-anonymization cronjob.

=cut

async sub auto_anonymize_candidates {
    my $collector_db = BOM::Database::ClientDB->new({
            broker_code => 'FOG',
            operation   => 'collector',
        })->db->dbic;

    my @canceled_candidates = $collector_db->run(
        fixup => sub {
            return $_->selectall_array(
                "SELECT * FROM users.get_anonymization_candidates('', ?, FALSE) UNION SELECT * FROM users.get_anonymization_candidates('', ?, FALSE)",
                {Slice => {}}, 'approved', 'postponed'
            );
        });

    for my $candidate (@canceled_candidates) {
        # reset the reviewed removed anonymization candidates and report them.
        $collector_db->run(
            fixup => sub {
                return $_->do(
                    "SELECT users.set_anonymization_confirmation_status(?,?,?,?)",
                    {Slice => {}},
                    $candidate->{binary_user_id} + 0,
                    'pending', 'Retention period was reset by user activity', 'system'
                );
            });
    }

    _send_reset_candidates_report(@canceled_candidates) if @canceled_candidates;

    my $limit = BOM::Config::Runtime->instance->app_config->compliance->auto_anonymization_daily_limit;
    my @data  = $collector_db->run(
        fixup => sub {
            # Select clients only if all siblings are ready for anonymization: user_can_anon = TRUE and compliance_confirmation = 'approved'
            # (we don't expect it happen in normal circumstances; but it's better to safeguard the code against currupt data)
            return $_->selectcol_arrayref(<<~"SQL", undef, '', 'approved', $limit);
                SELECT STRING_AGG(loginids, ' ' ORDER BY loginids) FROM users.get_anonymization_candidates(?, ?, TRUE) c
                    LEFT JOIN users.anonymization_candidates sibling ON c.binary_user_id = sibling.binary_user_id AND NOT (sibling.user_can_anon AND sibling.compliance_confirmation = 'approved')
                    WHERE sibling.loginid IS NULL
                    GROUP BY c.binary_user_id LIMIT ?
                SQL
        })->@*;

    # keep just a single logindid for each user to avoid "already anonymized" error
    @data = map { [split(' ', $_)]->[0] } @data;

    return await bulk_anonymization({
            data  => \@data,
            title => 'Auto Anonymization'
        }) if scalar @data;

    return 1;
}

=head2 _send_reset_candidates_report

Send email reporitng the list of candidates with retention period reset after compliance confirmation (postponed or approved). 
It gets a single argument:

=over 3

=item * C<candidates> - A list of candidates whose rentetion period is reset

=back

return undef

=cut

sub _send_reset_candidates_report {
    my @candidates = @_;

    my $email_subject = 'Auto-anonymization canceled after complinace confirmation ' . Date::Utility->new->date;
    my $from_email    = $BRANDS->emails('no-reply');
    my $to_email      = $BRANDS->emails('compliance');

    my $tt = Template->new(ABSOLUTE => 1);
    $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/anonymization_reset_candidates.html.tt', {data => \@candidates},
        \my $body);
    if ($tt->error) {
        $log->warn("Template error " . $tt->error);
        return undef;
    }

    Email::Stuffer->from($from_email)->to($to_email)->subject($email_subject)->html_body($body)->send
        or warn "Sending email from $from_email to $to_email subject $email_subject failed";

    return undef;
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
    my ($failures, $successes, $title) = @_;
    my $number_of_failures  = scalar keys %$failures;
    my $number_of_successes = scalar keys %$successes;
    my $email_subject       = ($title // 'Anonymization') . ' report for ' . Date::Utility->new->date;

    my $from_email = $BRANDS->emails('no-reply');
    my $to_email   = $BRANDS->emails('compliance_dpo');
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

async sub _anonymize {
    my $loginid = shift;
    my ($user, @clients_hashref);
    my @mt5_activeids;
    my @mt5_inactiveids;
    try {
        my $client = BOM::User::Client->new({loginid => $loginid});
        return "clientNotFound" unless ($client);
        $user = $client->user;
        return "userNotFound" unless $user;
        return "userAlreadyAnonymized" if $user->email =~ /\@deleted\.binary\.user$/;

        my @mt_logins = sort $user->get_mt5_loginids(include_all_status => 1);

        if (scalar(@mt_logins)) {
            foreach my $mt5_account (@mt_logins) {
                try {
                    await BOM::MT5::User::Async::get_user($mt5_account);
                    push @mt5_activeids, $mt5_account;
                } catch ($e) {
                    if ($e->{error} =~ m/ERR_NOTFOUND/i) {
                        $log->errorf("Account not found while retrieving user '%s' from MT5 : %s", $mt5_account, $e);
                        try {
                            my $mt5_archived_account = await BOM::MT5::User::Async::get_user_archive($mt5_account);
                            push @mt5_inactiveids, $mt5_account if $mt5_archived_account;
                        } catch ($e) {
                            $log->errorf("Error occured while retrieving user from get_user_archive api call'%s' from MT5 : %s", $mt5_account, $e);
                        }
                    }
                }
            }
        }

        return "activeClient" if @mt5_activeids;

        return "activeClient" unless ($user->valid_to_anonymize);

        # Delete oneall data
        my $oneall_user_data = $user->oneall_data;
        return "oneallError" unless BOM::OAuth::OneAll::anonymize_user($oneall_user_data);

        # Delete data on close io
        return "closeIOError" unless BOM::Platform::CloseIO->new(user => $user)->anonymize_user();

        # Delete data on customer io.
        await BOM::Event::Actions::CustomerIO->new->anonymize_user($user);

        # Delete desk data from s3
        return "deskError" unless await BOM::Platform::Desk->new(user => $user)->anonymize_user();

        my $redis = _redis_payment_write();

        @clients_hashref = $client->user->clients(
            include_disabled   => 1,
            include_duplicated => 1,
        );

        if (scalar(@mt5_inactiveids)) {
            my @error_ids;
            foreach my $mt5_account (@mt5_inactiveids) {
                my $active_id;
                my $archive_id;
                try {
                    my $mt5_archivedid = await BOM::MT5::User::Async::get_user_archive($mt5_account);
                    await BOM::MT5::User::Async::user_restore($mt5_archivedid);
                    my $updated_userinfo = _prepare_params_for_update($mt5_archivedid);
                    await BOM::MT5::User::Async::update_user($updated_userinfo);
                    await BOM::MT5::User::Async::user_archive($mt5_account);
                } catch ($e) {
                    $log->infof("An error occured while anonymizing MT5 account '%s' from MT5 : %s", $mt5_account, $e);
                    try {
                        $active_id  = await BOM::MT5::User::Async::get_user($mt5_account);
                        $archive_id = await BOM::MT5::User::Async::user_archive($mt5_account) if $active_id;
                        die "Error in anonymization process" unless $archive_id;
                    } catch ($e) {
                        $log->errorf("An error occured while rearchiving the MT5 Account during anonymization process '%s' from MT5 : %s",
                            $mt5_account, $e);
                        push @error_ids, $mt5_account;
                    }
                }
            }
            return "mt5AnonymizationError" if @error_ids;
        }

        # Anonymize data for all the user's clients
        foreach my $cli (@clients_hashref) {

            # Skip if client already anonymized
            next if $cli->email =~ /\@deleted\.binary\.user$/;

            # Delete documents from S3 because after anonymization the filename will be changed.
            $cli->remove_client_authentication_docs_from_S3();

            # Set client status to disabled to prevent user from doing any future actions
            $cli->status->setnx('disabled', 'system', 'Anonymized client');

            # Remove all user tokens
            my $token = BOM::Platform::Token::API->new;
            $token->remove_by_loginid($cli->loginid);

            $cli->anonymize_client();

            await _df_anonymize($redis, $cli);
        }

        return "userNotFound" unless $client->anonymize_associated_user_return_list_of_siblings();
    } catch ($error) {
        exception_logged();
        $log->errorf('Anonymization failed: %s', $error);
        return "anonymizationFailed";
    }
    return "successful";
}

=head2 _df_anonymize

Push a new DF anonymization request in the Redis queue.

It takes the following arguments:

=over 4

=item * C<$redis> - a redis client instance

=item * C<$cli> - the client to be anonymized

=back

Returns a L<Future> for the result of the Redis ZADD command.

=cut

async sub _df_anonymize {
    my ($redis, $cli) = @_;

    # skip DF anonymization if virtual
    return if $cli->is_virtual;

    # skip crypto accounts for DF anonymization
    return unless $cli->currency;

    return unless LandingCompany::Registry::get_currency_type($cli->currency) eq 'fiat';

    return await $redis->zadd(DF_ANONYMIZATION_KEY, time,
        join('|', $cli->loginid, BOM::Platform::Doughflow::get_sportsbook_by_short_code($cli->landing_company->short, $cli->currency)));
}

=head2 df_anonymization_done

Callback for DF anonymization process done.

It takes a hashref whose keys are loginids and the values are the raw response from df api anonymization endpoint.

The df api anonymization endpoint will always contain a `data` key whose value is a string that describes the result of the
anonymization process for the loginid given.

Returns B<1>.

=cut

async sub df_anonymization_done {
    my $args = shift;
    my $bulk = [];

    for my $loginid (keys $args->%*) {
        my $cli = BOM::User::Client->new({loginid => $loginid});

        next unless $cli;

        my $code  = $args->{$loginid}->{data} || next;
        my $redis = _redis_payment_write();

        if ($code =~ /^6 -/) {
            my $counter = await $redis->incr(DF_ANONYMIZATION_RETRY_COUNTER_KEY . $loginid);

            if ($counter <= DF_ANONYMIZATION_MAX_RETRY) {

                # retry
                $log->warnf('DF Anonymization retry: %s (%d times)', $loginid, $counter);
                stats_inc('df_anonymization.result.retry', {tags => ["loginid:$loginid"]});
                await _df_anonymize($redis, $cli);
            } else {

                # give up
                $log->errorf('DF Anonymization max retry attempts reached: %s', $loginid);
                stats_inc('df_anonymization.result.max_retry', {tags => ["loginid:$loginid"]});
            }

            await $redis->expire(DF_ANONYMIZATION_RETRY_COUNTER_KEY . $loginid, DF_ANONYMIZATION_RETRY_TTL);
        } else {
            push $bulk->@*, "<tr><td>$loginid</td><td>$code</td></tr>";

            if ($code eq 'OK') {
                stats_inc('df_anonymization.result.success');
            } else {
                $log->errorf('DF Anonymization error code: %s for %s', $code, $loginid);
                stats_inc('df_anonymization.result.error', {tags => ["result:$code", "loginid:$loginid"]});
            }
        }
    }

    if (scalar $bulk->@*) {
        my $from_email = $BRANDS->emails('no-reply');
        my $to_email   = $BRANDS->emails('compliance_dpo');

        # send the email with response from df api
        send_email({
                from    => $from_email,
                to      => $to_email,
                subject => 'Doughflow Anonymization Report',
                message => [
                    "Result of doughflow anonymization process:<br/><br/>",
                    "<table border='1'><tr><th>Loginid</th><th>Result</th><tr>",
                    $bulk->@*, "</table>"
                ],
                email_content_is_html => 1,
            });
    }

    return 1;
}

=head2 _prepare_params_for_update

Method prepares params for sending to mt5 server for user_update

=cut

sub _prepare_params_for_update {

    my $updated_userinfo = shift;
    my $mt5_loginid      = $updated_userinfo->{login};
    $mt5_loginid =~ s/MT[DR]?//;
    $updated_userinfo->{name}    = $mt5_loginid . "-deleted";
    $updated_userinfo->{address} = "deleted";
    $updated_userinfo->{city}    = "deleted";
    $updated_userinfo->{phone}   = "deleted";
    $updated_userinfo->{state}   = "deleted";
    $updated_userinfo->{zipCode} = "deleted";
    $updated_userinfo->{id}      = "deleted";
    $updated_userinfo->{email}   = $mt5_loginid . "\@deleted.binary.user";
    return $updated_userinfo;
}

1;
