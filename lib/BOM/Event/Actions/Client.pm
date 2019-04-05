package BOM::Event::Actions::Client;

use strict;
use warnings;

no indirect;

use Log::Any qw($log);
use IO::Async::Loop;
use Net::Async::HTTP;
use WebService::Async::Onfido;
use Locale::Codes::Country qw(country_code2code);
use DataDog::DogStatsd::Helper;
use Brands;
use Try::Tiny;
use Template::AutoFilter;

use BOM::Config;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Email qw(send_email);
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::S3Client;
use BOM::Platform::Event::Emitter;
use BOM::Config::RedisReplicated;

# Number of seconds to allow for just the verification step.
use constant VERIFICATION_TIMEOUT => 60;

# Number of seconds to allow for the full document upload.
# We expect our documents to be small (<10MB) and all API calls
# to complete within a few seconds.
use constant UPLOAD_TIMEOUT => 60;

# Redis key namespace to store onfido applicant id
use constant ONFIDO_APPLICANT_KEY_PREFIX => 'ONFIDO::APPLICANT::ID::';

# Conversion from our database to the Onfido available fields
my %ONFIDO_DOCUMENT_TYPE_MAPPING = (
    passport                                     => 'passport',
    certified_passport                           => 'passport',
    selfie_with_id                               => 'live_photo',
    driverslicense                               => 'driving_licence',
    cardstatement                                => 'bank_statement',
    bankstatement                                => 'bank_statement',
    proofid                                      => 'national_identity_card',
    vf_face_id                                   => 'live_photo',
    vf_poa                                       => 'unknown',
    vf_id                                        => 'unknown',
    address                                      => 'unknown',
    proofaddress                                 => 'unknown',
    certified_address                            => 'unknown',
    docverification                              => 'unknown',
    certified_bank_details                       => 'unknown',
    professional_uk_high_net_worth               => 'unknown',
    amlglobalcheck                               => 'unknown',
    employment_contract                          => 'unknown',
    power_of_attorney                            => 'unknown',
    notarised                                    => 'unknown',
    frontofcard                                  => 'unknown',
    professional_uk_self_certified_sophisticated => 'unknown',
    experianproveid                              => 'unknown',
    backofcard                                   => 'unknown',
    tax_receipt                                  => 'unknown',
    payslip                                      => 'unknown',
    alldocs                                      => 'unknown',
    professional_eu_qualified_investor           => 'unknown',
    misc                                         => 'unknown',
    other                                        => 'unknown',
);

# Mapping to convert our database entries to the 'side' parameter in the
# Onfido API
my %ONFIDO_DOCUMENT_SIDE_MAPPING = (
    front => 'front',
    back  => 'back',
    photo => 'photo',
);

{
    my $onfido;

    # Provides an instance for communicating with the Onfido web API.
    # Since we're adding this to our event loop, it's a singleton - we
    # don't want to leak memory by creating new ones for every event.
    sub _onfido {
        return $onfido //= do {
            my $loop = IO::Async::Loop->new;
            $loop->add(my $api = WebService::Async::Onfido->new(token => BOM::Config::third_party()->{onfido}->{authorization_token}));
            $api;
            }
    }

    my $http;

    sub _http {
        return $http //= do {
            my $loop = IO::Async::Loop->new;
            my $http = Net::Async::HTTP->new(
                fail_on_error  => 1,
                pipeline       => 0,
                decode_content => 1,
                stall_timeout  => 30,
                user_agent     => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:66.0)',
            );
            $loop->add($http);
            $http;
            }

    }
}

=head2 document_upload

Called when we have a new document provided by the client.

These are typically received through one of two possible avenues:

=over 4

=item * backoffice manual upload

=item * client sends the document through the websockets binary upload

=back

Our handling in this event goes as far as making sure the content
is available to Onfido: we don't do the verification step here, but
we do B<trigger a verification event> if we think we have enough
information to process this client.

=cut

sub document_upload {
    my ($args) = @_;

    return try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $file_id = $args->{file_id}
            or die 'No file ID supplied?';

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        # We let the existing code in Future.pm track timing,
        # this allows us to rely on a single ->on_ready callback
        # to send information to Datadog.
        local $Future::TIMES = 1;

        my $loop   = IO::Async::Loop->new;
        my $onfido = _onfido();

        $log->debugf('Applying Onfido verification process for client %s', $loginid);
        my $file_data = $args->{content};

        # We need information from the database to confirm file name and date
        my $document_entry = _get_document_details(
            loginid => $loginid,
            file_id => $file_id
        );
        die 'Expired document ' . $document_entry->{expiration_date}
            if $document_entry->{expiration_date} and Date::Utility->new($document_entry->{expiration_date})->epoch < time;

        # We have an overall timeout for this entire operation - it won't
        # limit any SQL queries, but all network operations should be covered.
        Future->wait_any(
            $loop->timeout_future(after => UPLOAD_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido upload.') }),
            # Start with an applicant and the file data (which might come from S3
            # or be provided locally)
            Future->needs_all(
                _get_onfido_applicant(
                    onfido => $onfido,
                    client => $client
                ),
                (
                    defined($file_data)
                    ? do {
                        $log->debugf('Using file data directly from event');
                        Future->done($file_data);
                        }
                    : do {
                        my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});
                        my $url       = $s3_client->get_s3_url($document_entry->{file_name});

                        _http()->GET($url, connection => 'close')->transform(
                            done => sub {
                                shift->decoded_content;
                            }
                            )->on_ready(
                            sub {
                                my $f = shift;
                                DataDog::DogStatsd::Helper::stats_timing("event.document_upload.s3.download." . $f->state . ".elapsed", $f->elapsed,);
                            });
                        }
                )
                )->then(
                sub {
                    my ($applicant, $file_data) = @_;

                    $log->debugf('Applicant created: %s, uploading %d bytes for document', $applicant->id, length($file_data));

                    # NOTE that this is very dependent on our current filename format
                    my (undef, $type, $side, $file_type) = split /\./, $document_entry->{file_name};

                    $type = $ONFIDO_DOCUMENT_TYPE_MAPPING{$type} // 'unknown';
                    $side =~ s{^\d+_?}{};
                    $side = $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
                    $type = 'live_photo' if $side eq 'photo';
                    (
                        $type eq 'live_photo'
                        ? $onfido->live_photo_upload(
                            applicant_id => $applicant->id,
                            data         => $file_data,
                            filename     => $document_entry->{file_name},
                            )
                        : $onfido->document_upload(
                            applicant_id    => $applicant->id,
                            data            => $file_data,
                            filename        => $document_entry->{file_name},
                            issuing_country => uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
                            side            => $side,
                            type            => $type,
                        )
                        )->on_ready(
                        sub {
                            my $f = shift;
                            DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.upload." . $f->state . ".elapsed", $f->elapsed,);
                        }
                        )->then(
                        sub {
                            my ($doc) = @_;
                            $log->debugf('Document %s created for applicant %s', $doc->id, $applicant->id,);

                            # At this point, we may have enough information to start verification.
                            # Since this could vary by landing company, the logic ideally belongs there,
                            # but for now we're using the Onfido rules and assuming that we need 3 things
                            # in all cases:
                            # - proof of identity
                            # - proof of address
                            # - "live" photo showing the client holding one of the documents
                            # We start by pulling a full list of documents and photos for this applicant.
                            # Note that we *cannot* just use the database for this, because there's
                            # a race condition: if 2 documents are uploaded simultaneously, then we'll
                            # assume that we've also processed and sent to Onfido, but one of those may
                            # still be stuck in the queue.
                            $onfido->document_list(applicant_id => $applicant->id)->merge($onfido->photo_list(applicant_id => $applicant->id))
                                ->as_list->on_ready(
                                sub {
                                    my $f = shift;
                                    DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.list_documents." . $f->state . ".elapsed",
                                        $f->elapsed,);
                                }
                                )->then(
                                sub {
                                    $log->debugf('TODO: Need to emit ready_for_authentication event for %s (applicant ID %s)',
                                        $loginid, $applicant->id);
                                    Future->done;
                                });
                        });
                }
                )->on_fail(
                sub {
                    $log->errorf('An error occurred while uploading document to Onfido: %s', join(' ', @_));
                })
            )->get
    }
    catch {
        $log->errorf('Failed to process Onfido application: %s', $_);
        DataDog::DogStatsd::Helper::stats_inc("event.document_upload.failure",);
    };
}

=head2 ready_for_authentication

This event is triggered once we think we have enough information to do
a verification step for a client.

We expect documents to be fully uploaded and available, plus any data that
needs to be in external systems should also be in place.

For Onfido, this means the applicant and documents are created, and
everything should be ready to do the verification step.

=cut

sub ready_for_authentication {
    my ($args) = @_;

    return try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $applicant_id = $args->{applicant_id}
            or die 'No Onfido applicant ID supplied?';

        my ($broker) = $loginid =~ /^([A-Z]+)\d+$/
            or die 'could not extract broker code from login ID';

        my $loop   = IO::Async::Loop->new;
        my $onfido = _onfido();

        $log->debugf('Processing ready_for_authentication event for %s (applicant ID %s)', $loginid, $applicant_id);
        # We let the existing code in Future.pm track timing,
        # this allows us to rely on a single ->on_ready callback
        # to send information to Datadog.
        local $Future::TIMES = 1;
        Future->wait_any(
            $loop->timeout_future(after => VERIFICATION_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido verfication.') }),
            $onfido->applicant_check(
                applicant_id => $applicant_id,
                # We don't want Onfido to start emailing people
                suppress_form_emails => 1,
                # Used for reporting and filtering in the web interface
                tags => ['automated', $broker, $loginid],
                # Note that there are additional report types which are not currently useful:
                # - proof_of_address - only works for UK documents
                # - street_level - involves posting a letter and requesting the user enter
                # a verification code on the Onfido site
                reports => [qw(document facial_similarity identity watchlist)],
                # async flag if true will queue checks for processing and
                # return a response immediately
                async => 1,
                # The type is always "express" since we are sending data via API.
                # https://documentation.onfido.com/#check-types
                type => 'express',
                )->on_ready(
                sub {
                    my $f = shift;
                    DataDog::DogStatsd::Helper::stats_timing("event.ready_for_authentication.onfido.applicant_check." . $f->state . ".elapsed",
                        $f->elapsed,);
                }
                )->then(
                sub {
                    my ($check) = @_;
                    # In async mode, we may not have a genuine result here - but at the
                    # moment we should still get an instance of the class with result as
                    # "unknown", so the following code should continue to work:
                    my $result = $check->result;

                    # Map to something that can be standardised across other systems;
                    # this is currently an enum in the database.
                    my $our_result = {
                        clear        => 'pass',
                        rejected     => 'fail',
                        suspected    => 'fail',
                        caution      => 'maybe',
                        unidentified => 'maybe',
                    }->{$result} // 'unknown';

                    $log->infof('Onfido check result for %s (applicant %s): %s (%s)', $loginid, $applicant_id, $result, $our_result,);

                    my $start = Time::HiRes::time();
                    my $dbic  = BOM::Database::ClientDB->new({
                            client_loginid => $loginid,
                            operation      => 'replica',
                        }
                        )->db->dbic
                        or die "failed to get database connection for login ID " . $loginid;

                    $dbic->run(
                        fixup => sub {
                            $_->selectrow_hashref('select * from betonmarkets.record_client_authentication_result(?, ?, ?)',
                                undef, $loginid, 'onfido', $our_result);
                        });
                    my $elapsed = Time::HiRes::time() - $start;
                    DataDog::DogStatsd::Helper::stats_timing("event.ready_for_authentication.database.record_result.elapsed", $elapsed);

                    # At this point, either a database trigger or code directly in here would
                    # update the client status. For now, it's information only.
                    return Future->done;
                }
                )->on_fail(
                sub {
                    $log->errorf('An error occurred while processing Onfido verification: %s', join(' ', @_));
                })
            )->get
    }
    catch {
        $log->errorf('Failed to process Onfido verification: %s', $_);
        return Future->done;
    };
}

sub _get_onfido_applicant {
    my (%args) = @_;

    my $client = $args{client};
    my $onfido = $args{onfido};

    return Future->call(
        sub {
            my $applicant_id = BOM::Config::RedisReplicated::redis_read()->get(ONFIDO_APPLICANT_KEY_PREFIX . $client->binary_user_id);
            Future->fail() unless $applicant_id;

            Future->done($applicant_id);
        }
        )->then(
        sub {
            my $applicant_id = shift;
            $onfido->applicant_get(applicant_id => $applicant_id)->then(
                sub {
                    Future->done(shift);
                });
        }
        )->else(
        sub {
            $onfido->applicant_create(
                (map { $_ => $client->$_ } qw(first_name last_name email)),
                title   => $client->salutation,
                dob     => $client->date_of_birth,
                country => uc(country_code2code($client->place_of_birth, 'alpha-2', 'alpha-3')),
                # Multiple addresses are supported by Onfido. We only want to set up a single one.
                addresses => [{
                        building_number => $client->address_line_1,
                        street          => $client->address_line_2,
                        town            => $client->address_city,
                        state           => $client->address_state,
                        postcode        => $client->address_postcode,
                        country         => uc(country_code2code($client->residence, 'alpha-2', 'alpha-3')),
                    }
                ],
                )->then(
                sub {
                    my $applicant = shift;
                    BOM::Config::RedisReplicated::redis_write()->set(ONFIDO_APPLICANT_KEY_PREFIX . $client->binary_user_id, $applicant->id);
                    Future->done($applicant);
                }
                )->on_ready(
                sub {
                    my $f = shift;
                    DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create." . $f->state . ".elapsed", $f->elapsed,);
                });
        });
}

sub _get_document_details {
    my (%args) = @_;

    my $loginid = $args{loginid};
    my $file_id = $args{file_id};

    return do {
        my $start = Time::HiRes::time();
        my $dbic  = BOM::Database::ClientDB->new({
                client_loginid => $loginid,
                operation      => 'replica',
            }
            )->db->dbic
            or die "failed to get database connection for login ID " . $loginid;

        my $doc;
        try {
            $doc = $dbic->run(
                fixup => sub {
                    $_->selectrow_hashref(<<'SQL', undef, $loginid, $file_id);
SELECT id,
   file_name,
   expiration_date,
   comments,
   document_id,
   upload_date
FROM betonmarkets.client_authentication_document
WHERE client_loginid = ?
AND status != 'uploading'
AND id = ?
SQL
                });
            my $elapsed = Time::HiRes::time() - $start;
            DataDog::DogStatsd::Helper::stats_timing("event.document_upload.database.document_lookup.elapsed", $elapsed);
        }
        catch {
            die "An error occurred while getting document details ($file_id) from database for login ID $loginid.";
        };
        $doc;
    };
}

=head2 account_closure_event

Send email to CS that a client has closed their accounts.

=cut

sub account_closure {

    my $data = shift;

    my $brands        = Brands->new();
    my $system_email  = $brands->emails('system');
    my $support_email = $brands->emails('support');

    _send_email_account_closure_cs($data, $system_email, $support_email);

    _send_email_account_closure_client($data->{loginid}, $support_email);

    return undef;

}

sub _send_email_account_closure_cs {

    my ($data, $system_email, $support_email) = @_;

    my $loginid = $data->{loginid};
    my $user = BOM::User->new(loginid => $loginid);

    my @mt5_loginids = grep { $_ =~ qr/^MT[0-9]+$/ } $user->loginids;
    my $mt5_loginids_string = @mt5_loginids ? join ",", @mt5_loginids : undef;

    my $data_tt = {
        loginid               => $loginid,
        successfully_disabled => $data->{loginids_disabled},
        failed_disabled       => $data->{loginids_failed},
        mt5_loginids_string   => $mt5_loginids_string,
        reasoning             => $data->{closing_reason}};

    my $email_subject = "Account closure done by $loginid";

    # Send email to CS
    my $tt = Template::AutoFilter->new({
        ABSOLUTE => 1,
        ENCODING => 'utf8'
    });

    return try {
        $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/account_closure.html.tt', $data_tt, \my $html);
        die "Template error: @{[$tt->error]}" if $tt->error;

        die "failed to send email to CS for Account closure ($loginid)"
            unless Email::Stuffer->from($system_email)->to($support_email)->subject($email_subject)->html_body($html)->send();

        undef;
    }
    catch {
        $log->warn($_);
        undef;
    };
}

sub _send_email_account_closure_client {
    my ($loginid, $support_email) = @_;

    my $client = BOM::User::Client->new({loginid => $loginid});

    my $client_email_template = localize(
        "\
        <p><b>We're sorry you're leaving.</b></p>
        <p>You have requested to close your Binary.com accounts. This is to confirm that all your accounts have been terminated successfully.</p>
        <p>Thank you.</p>
        Team Binary.com
        "
    );

    send_email({
        from                  => $support_email,
        to                    => $client->email,
        subject               => localize("We're sorry you're leaving"),
        message               => [$client_email_template],
        use_email_template    => 1,
        email_content_is_html => 1,
        skip_text2html        => 1
    });

    return undef;
}

1;
