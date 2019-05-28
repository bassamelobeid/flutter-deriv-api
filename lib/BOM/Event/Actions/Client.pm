package BOM::Event::Actions::Client;

use strict;
use warnings;

=head1 NAME

BOM::Event::Actions::Client

=head1 DESCRIPTION

Provides handlers for client-related events.

=cut

no indirect;

use Log::Any qw($log);
use IO::Async::Loop;
use Locale::Codes::Country qw(country_code2code);
use DataDog::DogStatsd::Helper;
use Brands;
use Try::Tiny;
use Template::AutoFilter;
use List::Util qw(any);
use List::UtilsBy qw(rev_nsort_by);
use Future::Utils qw(fmap0);
use Future::AsyncAwait;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use Date::Utility;

use BOM::Config;
use BOM::Platform::Context qw(localize);
use BOM::Platform::Email qw(send_email);
use Email::Stuffer;
use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;
use BOM::Platform::S3Client;
use BOM::Platform::Event::Emitter;
use BOM::Config::RedisReplicated;
use BOM::Event::Services;

# Number of seconds to allow for just the verification step.
use constant VERIFICATION_TIMEOUT => 60;

# Number of seconds to allow for the full document upload.
# We expect our documents to be small (<10MB) and all API calls
# to complete within a few seconds.
use constant UPLOAD_TIMEOUT => 60;

# Redis key namespace to store onfido applicant id
use constant ONFIDO_APPLICANT_KEY_PREFIX     => 'ONFIDO::APPLICANT::ID::';
use constant ONFIDO_REQUEST_PER_USER_PREFIX  => 'ONFIDO::DAILY::REQUEST::PER::USER::';
use constant ONFIDO_REQUEST_PER_USER_LIMIT   => $ENV{ONFIDO_REQUEST_PER_USER_LIMIT} // 3;
use constant ONFIDO_REQUEST_PER_USER_TIMEOUT => $ENV{ONFIDO_REQUEST_PER_USER_TIMEOUT} // 24 * 60 * 60;
use constant ONFIDO_PENDING_REQUEST_PREFIX   => 'ONFIDO::PENDING::REQUEST::';
use constant ONFIDO_PENDING_REQUEST_TIMEOUT  => 20 * 60;

# Redis key namespace to store onfido results and link
use constant ONFIDO_REQUESTS_LIMIT => $ENV{ONFIDO_REQUESTS_LIMIT} // 1000;
use constant ONFIDO_LIMIT_TIMEOUT  => $ENV{ONFIDO_LIMIT_TIMEOUT}  // 24 * 60 * 60;
use constant ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY => 'ONFIDO_AUTHENTICATION_REQUEST_CHECK';
use constant ONFIDO_REQUEST_COUNT_KEY               => 'ONFIDO_REQUEST_COUNT';
use constant ONFIDO_CHECK_EXCEEDED_KEY              => 'ONFIDO_CHECK_EXCEEDED';
use constant ONFIDO_REPORT_KEY_PREFIX               => 'ONFIDO::REPORT::ID::';

use constant ONFIDO_SUPPORTED_COUNTRIES_KEY                    => 'ONFIDO_SUPPORTED_COUNTRIES';
use constant ONFIDO_SUPPORTED_COUNTRIES_URL                    => 'https://documentation.onfido.com/identityISOsupported.json';
use constant ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT                => $ENV{ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT} // 7 * 86400;                     # 1 week
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX  => 'ONFIDO::UNSUPPORTED::COUNTRY::EMAIL::PER::USER::';
use constant ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT => $ENV{ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT} // 24 * 60 * 60;

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

# When submitting checks, Onfido expects an identity document,
# so we prioritise the IDs that have a better chance of a good
# match. This does not cover all the types, but anything without
# a photo is unlikely to work well anyway.
my %ONFIDO_DOCUMENT_TYPE_PRIORITY = (
    uk_biometric_residence_permit => 5,
    passport                      => 4,
    passport_card                 => 4,
    national_identity_card        => 3,
    driving_licence               => 2,
    voter_id                      => 1,
    tax_id                        => 1,
    unknown                       => 0,
);

# List of document types that we use as proof of address
my @POA_DOCUMENTS_TYPE = qw(proofaddress payslip bankstatement cardstatement);

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

{
    # Provides an instance for communicating with the Onfido web API.
    # Since we're adding this to our event loop, it's a singleton - we
    # don't want to leak memory by creating new ones for every event.
    sub _onfido {
        return $services->onfido();
    }

    sub _smartystreets {
        return $services->smartystreets();
    }

    sub _http {
        return $services->http();
    }

    sub _redis_mt5user_read {
        return $services->redis_mt5user();
    }

    sub _redis_events_read {
        return $services->redis_events_read();
    }

    sub _redis_events_write {
        return $services->redis_events_write();
    }

    sub _redis_replicated_write {
        return $services->redis_replicated_write();
    }
}

=head2 document_upload

    Called when we have a new document provided by the client .

    These are typically received through one of two possible avenues :

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

    return if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido);

    return try {
        my $loginid = $args->{loginid}
            or die 'No client login ID supplied?';
        my $file_id = $args->{file_id}
            or die 'No file ID supplied?';

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        my $redis_events_write = _redis_events_write();
        $redis_events_write->connect->then(
            sub {
                return $redis_events_write->hsetnx('ADDRESS_VERIFICATION_TRIGGER', $client->binary_user_id, 1);
            }
            )->then(
            sub {
                my $is_not_triggered = shift;

                # trigger address verification if not already address_verified
                _address_verification(client => $client)->get if (not $client->status->address_verified and $is_not_triggered);

                return Future->done;
            })->retain;

        $log->debugf('Applying Onfido verification process for client %s', $loginid);
        my $file_data = $args->{content};

        # We need information from the database to confirm file name and date
        my $document_entry = _get_document_details(
            loginid => $loginid,
            file_id => $file_id
        );
        die 'Expired document ' . $document_entry->{expiration_date}
            if $document_entry->{expiration_date} and Date::Utility->new($document_entry->{expiration_date})->epoch < time;

        _send_email_notification_for_poa(
            document_entry => $document_entry,
            client         => $client
        )->get;

        my $loop   = IO::Async::Loop->new;
        my $onfido = _onfido();

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

                    return Future->fail('No applicant created for '
                            . $client->loginid
                            . ' with place of birth '
                            . $client->place_of_birth
                            . ' and residence '
                            . $client->residence)
                        unless $applicant;

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
                                    my @documents = @_;
                                    # Since the list of types may change, and we don't really have a good
                                    # way of mapping the Onfido data to our document types at the moment,
                                    # we use a basic heuristic of "if we sent it, this is one of the documents
                                    # that we need for verification, and we should be able to verify when
                                    # we have 2 or more including a live photo".
                                    return Future->done if @documents <= 2 or not grep { $_->isa('WebService::Async::Onfido::Photo') } @documents;
                                    $log->debugf('Emitting ready_for_authentication event for %s (applicant ID %s)', $loginid, $applicant->id);
                                    BOM::Platform::Event::Emitter::emit(
                                        ready_for_authentication => {
                                            loginid      => $loginid,
                                            applicant_id => $applicant->id,
                                        });

                                    return Future->done;
                                });
                        });
                }
                )->on_fail(
                sub {
                    my ($err, $category, @details) = @_;

                    $log->errorf('An error occurred while uploading document to Onfido: %s', $err) unless ($category // '') eq 'http';

                    # details is in res, req form
                    my ($res) = @details;
                    $log->errorf('An error occurred while uploading document to Onfido: %s with response %s', $err, ($res ? $res->content : ''));
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

        my @documents = $onfido->document_list(applicant_id => $applicant_id)->get;

        $log->infof('Have %d documents for applicant %s', 0 + @documents, $applicant_id);

        my ($doc, $poa_doc) = rev_nsort_by {
            ($_->side eq 'front' ? 10 : 1) * ($ONFIDO_DOCUMENT_TYPE_PRIORITY{$_->type} // 0)
        }
        @documents;

        my $client = BOM::User::Client->new({loginid => $loginid})
            or die 'Could not instantiate client for login ID ' . $loginid;

        if ($client->status->age_verification) {
            $log->infof("Onfido request aborted because %s is already age-verified.", $loginid);
            return Future->done("Onfido request aborted because $loginid is already age-verified.");
        }

        my $residence = uc(country_code2code($client->residence, 'alpha-2', 'alpha-3'));

        my ($request_count, $user_request_count);
        my $redis_events_write = _redis_events_write();
        # INCR Onfido check request count in Redis
        $redis_events_write->connect->then(
            sub {
                return Future->needs_all(
                    $redis_events_write->hget(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY),
                    $redis_events_write->get(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id),
                );
            }
            )->then(
            sub {
                $request_count      = shift // 0;
                $user_request_count = shift // 0;

                # Update DataDog Stats
                DataDog::DogStatsd::Helper::stats_inc('event.ready_for_authentication.onfido.applicant_check.count');

                if (!$args->{is_pending} && $user_request_count >= ONFIDO_REQUEST_PER_USER_LIMIT) {
                    return $redis_events_write->ttl(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id)->then(
                        sub {
                            my $time_to_live = shift;

                            $redis_events_write->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, ONFIDO_REQUEST_PER_USER_TIMEOUT)
                                ->retain()
                                if ($time_to_live < 0);

                            return Future->fail(
                                "Onfido authentication requests limit ${\ONFIDO_REQUEST_PER_USER_LIMIT} is hit by $loginid (to be expired in $time_to_live seconds)."
                            );
                        });
                }
                return Future->done($request_count);
            }
            )->then(
            sub {
                my $request_count = shift;

                if ($request_count >= ONFIDO_REQUESTS_LIMIT) {
                    # NOTE: We do not send email again if we already send before
                    my $redis_data = encode_json_utf8({
                        creation_epoch => Date::Utility->new()->epoch,
                        has_email_sent => 1
                    });

                    return $redis_events_write->hsetnx(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_CHECK_EXCEEDED_KEY, $redis_data)->then(
                        sub {

                            return Future->done({
                                request_count  => $request_count,
                                limit_exceeded => 1,
                                send_email     => shift
                            });
                        });
                }
                return Future->done({
                    request_count  => $request_count,
                    limit_exceeded => 0,
                    send_email     => 0
                });
            }
            )->then(
            sub {
                my $args = shift;
                my ($request_count, $limit_exceeded, $send_email) = @{$args}{qw/request_count limit_exceeded send_email/};

                if ($limit_exceeded) {
                    if ($send_email) {
                        _send_email_onfido_check_exceeded_cs($request_count);
                    }

                    return Future->fail('We exceeded our Onfido authentication check request per day');
                } else {
                    return Future->done();
                }
            }
            )->then(
            sub {
                Future->wait_any(
                    $loop->timeout_future(after => VERIFICATION_TIMEOUT)->on_fail(sub { $log->errorf('Time out waiting for Onfido verfication.') }),
                    $onfido->applicant_check(
                        applicant_id => $applicant_id,
                        # We don't want Onfido to start emailing people
                        suppress_form_emails => 1,
                        # Used for reporting and filtering in the web interface
                        tags => ['automated', $broker, $loginid, $residence],
                        # Note that there are additional report types which are not currently useful:
                        # - proof_of_address - only works for UK documents
                        # - street_level - involves posting a letter and requesting the user enter
                        # a verification code on the Onfido site
                        # plus others that would require the feature to be enabled on the account:
                        # - identity
                        # - watchlist
                        # for facial similarity we are passing document id for document
                        # that onfido will use to compare photo uploaded
                        reports => [{
                                name      => 'document',
                                documents => [$doc->id],
                            },
                            {
                                name      => 'facial_similarity',
                                variant   => 'standard',
                                documents => [$doc->id],
                            },
                            # We also submit a POA document to see if we can extract any information from it
                            (
                                $poa_doc
                                ? {
                                    name      => 'document',
                                    documents => [$poa_doc->id],
                                    }
                                : ())
                        ],
                        # async flag if true will queue checks for processing and
                        # return a response immediately
                        async => 1,
                        # The type is always "express" since we are sending data via API.
                        # https://documentation.onfido.com/#check-types
                        type => 'express',
                        )->on_ready(
                        sub {
                            my $f = shift;
                            DataDog::DogStatsd::Helper::stats_timing(
                                "event.ready_for_authentication.onfido.applicant_check." . $f->state . ".elapsed",
                                $f->elapsed,);
                        }
                        )->on_done(
                        sub {
                            Future->needs_all(
                                $redis_events_write->hincrby(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_REQUEST_COUNT_KEY, 1)->then(
                                    sub {
                                        return $redis_events_write->expire(ONFIDO_AUTHENTICATION_CHECK_MASTER_KEY, ONFIDO_LIMIT_TIMEOUT)
                                            if (shift == 1);

                                        return Future->done;
                                    }
                                ),
                                $redis_events_write->incr(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id)->then(
                                    sub {
                                        my $user_count = shift;
                                        $log->debugf("Onfido check request triggered for %s with current request count=%d on %s",
                                            $loginid, $user_count, Date::Utility->new->datetime_ddmmmyy_hhmmss);

                                        return $redis_events_write->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id,
                                            ONFIDO_REQUEST_PER_USER_TIMEOUT)
                                            if ($user_count == 1);

                                        return Future->done;
                                    }
                                ),
                            )->retain;
                        }
                        )->on_fail(
                        sub {
                            my ($type, $message, $response, $request) = @_;

                            my $error_type = ($response and $response->content) ? decode_json_utf8($response->content)->{error}->{type} : '';

                            if ($error_type eq 'incomplete_checks') {
                                $log->debugf(
                                    'There is an existing request running for login_id: %s. The currenct request is pending until it finishes.',
                                    $loginid);
                                $args->{is_pending} = 1;
                                $redis_events_write->set(ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id, encode_json_utf8($args))->then(
                                    sub {
                                        $redis_events_write->expire(ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id,
                                            ONFIDO_PENDING_REQUEST_TIMEOUT);
                                    })->retain;

                            } else {
                                $log->errorf('An error occurred while processing Onfido verification: %s', join(' ', @_));
                            }
                        }
                        ),
                    )    # wait_any
            })->get;
    }
    catch {
        $log->errorf('Failed to process Onfido verification: %s', $_);
        return Future->done;
    };
}

sub client_verification {
    my ($args) = @_;
    $log->infof('Client verification with %s', $args);

    return try {
        my $url = $args->{check_url};
        $log->infof('Had client verification result %s with check URL %s', $args->{status}, $args->{check_url});

        my ($applicant_id, $check_id) = $url =~ m{/applicants/([^/]+)/checks/([^/]+)} or die 'no check ID found';
        _onfido()->check_get(
            check_id     => $check_id,
            applicant_id => $applicant_id,
            )->then(
            sub {
                my ($check) = @_;
                try {
                    my $result = $check->result;
                    # Map to something that can be standardised across other systems
                    my $check_status = {
                        clear        => 'pass',
                        rejected     => 'fail',
                        suspected    => 'fail',
                        consider     => 'maybe',
                        caution      => 'maybe',
                        unidentified => 'maybe',
                    }->{$result // 'unknown'} // 'unknown';

                    # All our checks are tagged by login ID, we don't currently retain
                    # any local mapping aside from this.
                    my @tags = $check->tags->@*;
                    my ($loginid) = grep { /^[A-Z]+[0-9]+$/ } @tags
                        or die "No login ID found in tags: @tags";

                    my $client = BOM::User::Client->new({loginid => $loginid})
                        or die 'Could not instantiate client for login ID ' . $loginid;
                    $log->infof('Onfido check result for %s (applicant %s): %s (%s)', $loginid, $applicant_id, $result, $check_status);

                    my $redis_events_write = _redis_events_write();
                    $redis_events_write->connect->then(
                        sub {
                            $redis_events_write->hmset(
                                ONFIDO_REPORT_KEY_PREFIX . $client->binary_user_id,
                                status => $check_status,
                                url    => $check->results_uri
                            );
                        }
                        )->then(
                        sub {
                            return Future->done(@_);
                        }
                        )->on_fail(
                        sub {
                            $log->errorf('Error occured when saving %s report data to Redis', $client->loginid);
                        })->get;

                    my $pending_key = ONFIDO_PENDING_REQUEST_PREFIX . $client->binary_user_id;
                    $redis_events_write->get($pending_key)->then(
                        sub {
                            my $args = shift;
                            if (($check_status ne 'pass') and $args) {
                                $log->debugf('Onfido check failed. Resending the last pending request: %s', $args);
                                BOM::Platform::Event::Emitter::emit(ready_for_authentication => decode_json_utf8($args));
                            }
                            $redis_events_write->del($pending_key)->then(
                                sub {
                                    $log->debugf('Onfido pending key cleared');
                                });
                        })->retain;

                    # if overall result of check is pass then set status and
                    # return early, else check individual report result
                    if ($check_status eq 'pass') {
                        _update_client_status(
                            client  => $client,
                            status  => 'age_verification',
                            message => 'Onfido - age verified'
                        );
                        return Future->done;
                    }

                    $check->reports
                        # Skip facial similarity:
                        # For current selfie we ask them to submit with ID document
                        # that leads to sub optimal facial images and hence, it leads
                        # to lot of negatives for Onfido checks
                        # TODO: remove this check when we have fully integrated Onfido
                        ->filter(name => 'document')->as_list->then(
                        sub {
                            my @reports = @_;
                            if (any { $_->result eq 'clear' } @reports) {
                                _update_client_status(
                                    client  => $client,
                                    status  => 'age_verification',
                                    message => 'Onfido - age verified'
                                );
                            } else {
                                _send_report_not_clear_status_email($loginid, @reports ? $reports[0]->result : 'blank');
                            }

                            return Future->done;
                        }
                        )->on_fail(
                        sub {
                            $log->errorf('An error occurred while retrieving reports for client %s check %s: %s', $loginid, $check->id, $_[0]);
                        });
                }
                catch {
                    $log->errorf('Failed to do verification callback - %s', $_);
                    Future->fail($_);
                }
            })->get;
    }
    catch {
        $log->errorf('Exception while handling client verification result: %s', $_);
    }
}

=head2 sync_onfido_details

Sync the client details from our system with Onfido

=cut

sub sync_onfido_details {
    my $data = shift;

    return if (BOM::Config::Runtime->instance->app_config->system->suspend->onfido);

    return try {

        my $loginid = $data->{loginid} or die 'No loginid supplied';
        my $client = BOM::User::Client->new({loginid => $loginid});

        my $applicant_id = BOM::Config::RedisReplicated::redis_read()->get(ONFIDO_APPLICANT_KEY_PREFIX . $client->binary_user_id);

        # Only for users that are registered in onfido
        return Future->done() unless $applicant_id;

        # Instantiate client and onfido object
        my $client_details_onfido = _client_onfido_details($client);

        $client_details_onfido->{applicant_id} = $applicant_id;

        _onfido()->applicant_update(%$client_details_onfido)->then(
            sub {
                Future->done(shift);
            })->get;

    }
    catch {
        $log->errorf('Failed to update deatils in Onfido: %s', $_);
        return Future->done;
    };
}

=head2 verify_address

This event is triggered once client or someone from backoffice
have updated client address.

It first clear existing address_verified status and then
request again for new address.

=cut

sub verify_address {
    my ($args) = @_;

    my $loginid = $args->{loginid}
        or die 'No client login ID supplied?';

    my $client = BOM::User::Client->new({loginid => $loginid})
        or die 'Could not instantiate client for login ID ' . $loginid;

    # clear existing status
    $client->status->clear_address_verified();

    return _address_verification(client => $client)->get;
}

sub _address_verification {
    my (%args) = @_;

    my $client = $args{client};

    $log->infof('Verifying address');

    my $freeform = join(' ',
        grep { length } $client->address_line_1,
        $client->address_line_2, $client->address_city, $client->address_state, $client->address_postcode);

    my %details = (
        freeform => $freeform,
        country  => uc(country_code2code($client->residence, 'alpha-2', 'alpha-3')),
        # Need to pass this if you want to do verification
        geocode => 'true',
    );
    $log->infof('Address details %s', \%details);

    my $redis_events_read = _redis_events_read();
    return $redis_events_read->connect->then(
        sub {
            $redis_events_read->hget('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id, $freeform . ($client->residence // ''));
        }
        )->then(
        sub {
            my $check_already_performed = shift;

            if ($check_already_performed) {
                $log->debugf('Returning as address verification already performed for same details.');
                return Future->done;
            }

            # Next step is an address check. Let's make sure that whatever they
            # are sending is valid at least to locality level.
            return _smartystreets()->verify(%details)->on_done(
                sub {
                    my ($addr) = @_;

                    my $status = $addr->status;
                    $log->infof('Smartystreets verification status: %s', $status);
                    $log->debugf('Address info back from SmartyStreets is %s', {%$addr});

                    unless ($addr->accuracy_at_least('locality')) {
                        DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.failure', {tags => [$status]});
                        $log->warnf('Inaccurate address - only verified to %s precision', $addr->address_precision);
                        return Future->done;
                    }

                    DataDog::DogStatsd::Helper::stats_inc('smartystreet.verification.success', {tags => [$status]});
                    $log->infof('Address verified with accuracy of locality level by smartystreet.');

                    _update_client_status(
                        client  => $client,
                        status  => 'address_verified',
                        message => 'SmartyStreets - address verified'
                    );

                    my $redis_events_write = _redis_events_write();
                    $redis_events_write->connect->then(
                        sub {
                            $redis_events_write->hset('ADDRESS_VERIFICATION_RESULT' . $client->binary_user_id,
                                $freeform . ($client->residence // ''), $status);
                        })->retain;

                    return Future->done;
                }
                )->on_fail(
                sub {
                    $log->errorf('Address lookup failed for %s - %s', $client->loginid, $_[0]);
                    return Future->fail;
                }
                )->on_ready(
                sub {
                    my $f = shift;
                    DataDog::DogStatsd::Helper::stats_timing("event.address_verification.smartystreet.verify." . $f->state . ".elapsed", $f->elapsed);
                });
        });
}

=head2 _is_supported_country

Check if the passed country is supported by Onfido.

=over 4

=item * C<$country> - two letter country code to check for Onfido support

=back

=cut

async sub _is_supported_country {
    my ($country) = @_;

    my $countries_list;
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;

    $countries_list = await $redis_events_read->get(ONFIDO_SUPPORTED_COUNTRIES_KEY);
    if ($countries_list) {
        $countries_list = decode_json_utf8($countries_list);
    } else {
        my $onfido_countries = await _http()->GET(ONFIDO_SUPPORTED_COUNTRIES_URL);
        if ($onfido_countries) {
            $onfido_countries = decode_json_utf8($onfido_countries->content);
            $countries_list->{uc(country_code2code($_->{alpha3}, 'alpha-3', 'alpha-2'))} = $_->{supported_identity_report} + 0 for @$onfido_countries;

            my $redis_events_write = _redis_events_write();
            await $redis_events_write->connect;
            await $redis_events_write->set(ONFIDO_SUPPORTED_COUNTRIES_KEY, encode_json_utf8($countries_list));
            await $redis_events_write->expire(ONFIDO_SUPPORTED_COUNTRIES_KEY, ONFIDO_SUPPORTED_COUNTRIES_TIMEOUT);
        }
    }

    return $countries_list->{uc $country} // 0;
}

async sub _get_onfido_applicant {
    my (%args) = @_;

    my $client = $args{client};
    my $onfido = $args{onfido};

    my $country = $client->place_of_birth // $client->residence;
    my $is_supported_country = _is_supported_country($country)->get;
    unless ($is_supported_country) {
        DataDog::DogStatsd::Helper::stats_inc('onfido.unsupported_country', {tags => [$country]});
        await _send_email_onfido_unsupported_country_cs($client);
        $log->debugf('Document not uploaded to Onfido as client is from list of countries not supported by Onfido');
        return undef;
    }

    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;
    my $applicant_id = await $redis_events_read->get(ONFIDO_APPLICANT_KEY_PREFIX . $client->binary_user_id);

    if ($applicant_id) {
        $log->debugf('Applicant id already exists, returning that instead of creating new one');
        return await $onfido->applicant_get(applicant_id => $applicant_id);
    }

    my $start     = Time::HiRes::time();
    my $applicant = await $onfido->applicant_create(%{_client_onfido_details($client)});
    my $elapsed   = Time::HiRes::time() - $start;

    if ($applicant) {
        DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.done.elapsed", $elapsed);

        my $redis_events_write = _redis_events_write();
        await $redis_events_write->connect;

        await $redis_events_write->set(ONFIDO_APPLICANT_KEY_PREFIX . $client->binary_user_id, $applicant->id);
    } else {
        DataDog::DogStatsd::Helper::stats_timing("event.document_upload.onfido.applicant_create.failed.elapsed", $elapsed);
    }

    return $applicant;
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
   upload_date,
   document_type
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

sub _update_client_status {
    my (%args) = @_;

    my $client = $args{client};
    $log->infof('Updating status on %s to %s (%s)', $client->loginid, $args{status}, $args{message});
    $client->status->set($args{status}, 'system', $args{message});

    return;
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

=head2 _send_report_not_clear_status_email

Send email to CS when onfido return status is nor clear
because of which we were not able to mark client as age_verified

=cut

sub _send_report_not_clear_status_email {
    my $loginid = shift;
    my $result  = shift;

    my $email_subject = "Automated age verification failed for $loginid";

    return try {
        die "failed to send email to CS for automated age verification failure ($loginid)"
            unless Email::Stuffer->from('no-reply@binary.com')->to('authentications@binary.com')->subject($email_subject)
            ->text_body(
            "We were unable to automatically mark client as age verified for client ($loginid), as onfido result was marked as $result. Please check and verify."
            )->send();

        undef;
    }
    catch {
        $log->warn($_);
        undef;
    };
}

=head2 _send_email_notification_for_poa

Send email to CS when client submits a proof of address
document.

- send only if client is not fully authenticated
- send only if client has mt5 financial account

need to extend later for all landing companies

=cut

async sub _send_email_notification_for_poa {
    my (%args) = @_;

    my $document_entry = $args{document_entry};
    my $client         = $args{client};

    # no need to notify if document is not POA
    return undef unless (any { $_ eq $document_entry->{document_type} } @POA_DOCUMENTS_TYPE);

    # don't send email if client is already authenticated
    return undef if $client->fully_authenticated();

    my $send_poa_email = sub {
        my $redis_replicated_write = _redis_replicated_write();
        $redis_replicated_write->connect->then(
            sub {
                $redis_replicated_write->hsetnx('EMAIL_NOTIFICATION_POA', $client->binary_user_id, 1);
            }
            )->then(
            sub {
                my $need_to_send_email = shift;
                # using replicated one
                # as this key is used in backoffice as well
                Email::Stuffer->from('no-reply@binary.com')->to('authentications@binary.com')
                    ->subject('New uploaded POA document for: ' . $client->loginid)
                    ->text_body('New proof of address document was uploaded for ' . $client->loginid)->send()
                    if $need_to_send_email;
            });
    };

    # send email for landing company other than costarica
    # TODO: remove this landing company check
    # when we enable it for all landing companies
    # this should be a config in landing company
    unless ($client->landing_company->short eq 'svg') {
        $send_poa_email->()->retain;
        return undef;
    }

    my @mt_loginid_keys = map { /^MT(\d+)$/ ? "MT5_USER_GROUP::$1" : () } $client->user->loginids;

    return undef unless scalar(@mt_loginid_keys);

    my $redis_mt5_user = _redis_mt5user_read();
    await $redis_mt5_user->connect;
    my $mt5_groups = await $redis_mt5_user->mget(@mt_loginid_keys);

    # loop through all mt5 loginids check
    # mt5 group has advanced|standard then
    # its considered as financial
    if (any { $_ =~ /_standard|_advanced/ } @$mt5_groups) {
        $send_poa_email->()->retain;
    }
    return undef;
}

sub _send_email_onfido_check_exceeded_cs {
    my $request_count        = shift;
    my $brands               = Brands->new();
    my $system_email         = $brands->emails('system');
    my @email_recipient_list = ($brands->emails('support'), $brands->emails('compliance_alert'));
    my $email_subject        = 'Onfido request count limit exceeded';
    my $email_template       = "\
        <p><b>IMPORTANT: We exceeded our Onfido authentication check request per day..</b></p>
        <p>We have sent about $request_count requests which exceeds (" . ONFIDO_REQUESTS_LIMIT . "\)
        our own request limit per day with Onfido server.</p>

        Team Binary.com
        ";

    my $email_status =
        Email::Stuffer->from($system_email)->to(@email_recipient_list)->subject($email_subject)->html_body($email_template)->send();
    unless ($email_status) {
        $log->warn('failed to send Onfido check exceeded email.');
        return 0;
    }

    return 1;
}

=head2 _send_email_onfido_unsupported_country_cs

Send email to CS when Onfido does not support the client's country.

=cut

async sub _send_email_onfido_unsupported_country_cs {
    my ($client) = @_;

    # Prevent sending multiple emails for the same user
    my $redis_key         = ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_PREFIX . $client->binary_user_id;
    my $redis_events_read = _redis_events_read();
    await $redis_events_read->connect;
    return undef if await $redis_events_read->exists($redis_key);

    my $email_subject  = "Automated age verification failed for " . $client->loginid;
    my $email_template = "\
        <p>Client residence is not supported by Onfido. Please verify age of client manually.</p>
        <p>
            <b>loginid:</b> " . $client->loginid . "\
            <b>place of birth:</b> " . $client->place_of_birth . "\
            <b>residence:</b> " . $client->residence . "\
        </p>

        Team Binary.com
        ";

    my $email_status =
        Email::Stuffer->from('no-reply@binary.com')->to('authentications@binary.com')->subject($email_subject)->html_body($email_template)->send();

    if ($email_status) {
        my $redis_events_write = _redis_events_write();
        await $redis_events_write->connect;
        await $redis_events_write->set($redis_key, 1);
        await $redis_events_write->expire($redis_key, ONFIDO_UNSUPPORTED_COUNTRY_EMAIL_PER_USER_TIMEOUT);
    } else {
        $log->warn('failed to send Onfido unsupported country email.');
        return 0;
    }

    return 1;
}

=head2 social_responsibility_check

This check is to verify whether clients are at-risk in trading, and this check is done on an on-going basis.
The checks to be done are in the social_responsibility_check.yml file in bom-config.
If a client has breached certain thresholds, then an email will be sent to the
social responsibility team for further action.
After the email has been sent, the monitoring starts again.

This is required as per the following document: https://www.gamblingcommission.gov.uk/PDF/Customer-interaction-%E2%80%93-guidance-for-remote-gambling-operators.pdf
(Read pages 2,4,6)

NOTE: This is for MX-MLT clients only (Last updated: 1st May, 2019)

=cut

sub social_responsibility_check {
    my $data = shift;

    my $loginid = $data->{loginid};

    my $redis = BOM::Config::RedisReplicated::redis_write();

    my $hash_key   = 'social_responsibility';
    my $event_name = $loginid . '_sr_check';

    my $client_sr_values = {};

    foreach my $sr_key (qw/num_contract turnover losses deposit_amount deposit_count/) {
        $client_sr_values->{$sr_key} = $redis->hget($hash_key, $loginid . '_' . $sr_key) // 0;
    }

    # Remove flag from redis
    $redis->hdel($hash_key, $event_name);

    foreach my $threshold_list (@{BOM::Config::social_responsibility_thresholds()->{limits}}) {

        my $hits_required = $threshold_list->{hits_required};

        my @breached_info;

        my $hits = 0;

        foreach my $attribute (keys %$client_sr_values) {

            my $client_attribute_val = $client_sr_values->{$attribute};
            my $threshold_val        = $threshold_list->{$attribute};

            if ($client_attribute_val >= $threshold_val) {
                push @breached_info,
                    {
                    attribute     => $attribute,
                    client_val    => $client_attribute_val,
                    threshold_val => $threshold_val
                    };

                $hits++;
            }
        }

        last unless $hits;

        if ($hits >= $hits_required) {

            my $brands        = Brands->new();
            my $system_email  = $brands->emails('system');
            my $sr_email      = $brands->emails('social_responsibility');
            my $email_subject = 'Social Responsibility Check required - ' . $loginid;

            my $tt = Template::AutoFilter->new({
                ABSOLUTE => 1,
                ENCODING => 'utf8'
            });

            my $data = {
                loginid       => $loginid,
                breached_info => \@breached_info
            };

            # Remove keys from redis
            $redis->hdel($hash_key, $loginid . '_' . $_) for keys %$client_sr_values;

            return try {
                $tt->process('/home/git/regentmarkets/bom-events/share/templates/email/social_responsibiliy.html.tt', $data, \my $html);
                die "Template error: @{[$tt->error]}" if $tt->error;

                die "failed to send social responsibility email ($loginid)"
                    unless Email::Stuffer->from($system_email)->to($sr_email)->subject($email_subject)->html_body($html)->send();

                undef;
            }
            catch {
                $log->warn($_);
                undef;
            };
        }
    }

    return undef;
}

=head2 _client_onfido_details

Generate the list of client personal details needed for Onfido API

=cut

sub _client_onfido_details {
    my $client = shift;

    return {
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
            }]};
}

1;
