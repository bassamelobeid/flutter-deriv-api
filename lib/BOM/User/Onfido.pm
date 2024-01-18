package BOM::User::Onfido;

=head1 Description

This file handles all the Onfido related codes

=cut

use strict;
use warnings;

use BOM::Database::UserDB;
use Syntax::Keyword::Try;
use Date::Utility;
use JSON::MaybeUTF8            qw(decode_json_utf8 encode_json_utf8);
use Locale::Codes::Country     qw(country_code2code);
use DataDog::DogStatsd::Helper qw(stats_inc);
use List::Util                 qw(any first uniq all);
use BOM::Config::Redis;
use BOM::Platform::Event::Emitter;
use BOM::Platform::Utility;
use Log::Any qw($log);

use constant ONFIDO_REQUEST_PER_USER_PREFIX => 'ONFIDO::REQUEST::PER::USER::';
use constant ONFIDO_REQUEST_PENDING_PREFIX  => 'ONFIDO::REQUEST::PENDING::PER::USER::';
use constant ONFIDO_REQUEST_PENDING_TTL     => 86400;                                     # one day in second
use constant ONFIDO_ADDRESS_REQUIRED_FIELDS => qw(address_postcode residence);
use constant ONFIDO_SUSPENDED_UPLOADS       => 'ONFIDO::SUSPENDED::UPLOADS';

=head2 candidate_documents

Gets a stash of documents that:

=over 4

=item * are origin = `client` (manually uploaded)

=item * are status = `uploaded` (pending)

=item * are Onfido supported by document type

=item * are Onfido supported by issuing country

=back

It takes:

=over 4

=item * C<$user> - the current L<BOM::User>

=back

Returns an hashref with C<selfie> and C<documents> (arrayref), or C<undef> if there is no such documents.

=cut

sub candidate_documents {
    my ($user) = @_;
    my $client = $user->get_default_client;

    return $client->documents->pending_poi_bundle({
        onfido_country => 1,
    });
}

=head2 suspended_upload

Enqueues the current client into the "POI uploaded while Onfido is suspended" ZSET.

It takes the following:

=over 4

=item * C<$binary_user_id> - the binary user id of the current client.

=back

Returns C<undef>.

=cut

sub suspended_upload {
    my ($binary_user_id) = @_;

    my $redis = BOM::Config::Redis::redis_events();

    # adds the binary user id as the member
    # score is the current timestamp
    # theoretically, the lower the score the better to ensure higher priority
    $redis->zadd(ONFIDO_SUSPENDED_UPLOADS, 'NX', time, $binary_user_id);

    return undef;
}

=head2 store_onfido_applicant

Stores onfido check into the DB

=cut

sub store_onfido_applicant {
    my ($applicant, $user_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_applicant(?::TEXT,?::TIMESTAMP,?::TEXT,?::BIGINT)',
                    undef, $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
                    $applicant->href, $user_id,
                );
            });
    } catch ($e) {
        die "Fail to store Onfido applicant in DB: $e . Please check APPLICANT_ID: " . $applicant->id;
    }

    return;
}

=head2 get_user_onfido_applicant

Gets the user's latest applicant from users.onfido_applicant

=cut

sub get_user_onfido_applicant {
    my $user_id = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $user_id,);
            });
    } catch ($e) {
        die "Fail to get Onfido applicant in DB: $e . Please check USER_ID: $user_id";
    }

    return;
}

=head2 get_all_user_onfido_applicant

Gets all the user's applicant from users.onfido_applicant

=cut

sub get_all_user_onfido_applicant {
    my $user_id = shift;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_hashref('SELECT * FROM users.get_onfido_applicant(?::BIGINT)', 'id', {}, $user_id,);
            });
    } catch ($e) {
        die "Fail to get Onfido applicant in DB: $e . Please check USER_ID: $user_id";
    }

    return;
}

=head2 store_onfido_check

Stores onfido check into the DB

=cut

sub store_onfido_check {
    my ($applicant_id, $check) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_check(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT[])',
                    undef,
                    $check->id,
                    $applicant_id,
                    Date::Utility->new($check->created_at)->datetime_yyyymmdd_hhmmss,
                    $check->href,
                    'deprecated',
                    $check->status,
                    $check->result,
                    $check->results_uri,
                    $check->download_uri,
                    $check->tags,
                );
            });
    } catch ($e) {
        warn "Fail to store Onfido check in DB: $e . Please check CHECK_ID: " . $check->id;
    }

    return;
}

=head2 get_latest_onfido_check

Given a C<user_id>, get the latest onfido check from DB

Optionally, you may pass C<applicant_id> and C<limit>, both defaulting to NULL.

You may pass C<limit> = 1 to get only the `latest` one.

=cut

sub get_latest_onfido_check {
    my ($user_id, $applicant_id, $limit, $only_verified) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM users.get_onfido_checks(?::BIGINT, ?::TEXT, ?::BIGINT, ?::BOOL)',
                    undef, $user_id, $applicant_id, $limit, $only_verified ? 1 : 0);
            });
    } catch ($e) {
        die "Fail to get Onfido checks in DB: $e . Please check USER_ID: $user_id";
    }

    return;
}

=head2 get_onfido_checks

Gets an arrayref of all the Onfido checks made by the user.

=cut

sub get_onfido_checks {
    my ($user_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM users.get_onfido_checks(?::BIGINT)', {Slice => {}}, $user_id);
            });
    } catch ($e) {
        die "Fail to get Onfido checks in DB: $e . Please check USER_ID: $user_id";
    }

    return;
}

=head2 get_onfido_check

Gets a check by id.

=cut

sub get_onfido_check {
    my ($user_id, $applicant_id, $check_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM users.get_onfido_checks(?::BIGINT, ?::TEXT) WHERE id=?',
                    {Slice => {}},
                    $user_id, $applicant_id, $check_id
                );
            });
    } catch ($e) {
        die "Fail to get Onfido checks in DB: $e . Please check USER_ID: $user_id";
    }

    return;
}

=head2 update_onfido_check

Stores onfido check into the DB

=cut

sub update_onfido_check {
    my ($check) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do('select * from users.update_onfido_check_status(?::TEXT, ?::TEXT, ?::TEXT)',
                    undef, $check->id, $check->status, $check->result,);
            });
    } catch ($e) {
        warn "Fail to update Onfido check in DB: $e . Please check CHECK_ID: " . $check->id;
    }

    return;
}

=head2 store_onfido_report

Stores onfido report into the DB

=cut

sub store_onfido_report {
    my ($check, $report) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_report(?::TEXT, ?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::JSONB, ?::JSONB)',
                    undef,
                    $report->id,
                    $check->id,
                    $report->name,
                    Date::Utility->new($report->created_at)->datetime_yyyymmdd_hhmmss,
                    $report->status,
                    $report->result,
                    $report->sub_result,
                    $report->variant,
                    encode_json_utf8($report->breakdown),
                    encode_json_utf8($report->properties),
                );
            });
    } catch ($e) {
        warn "Fail to store Onfido report in DB: $e . Please check REPORT_ID: " . $report->id;
    }

    return;
}

=head2 get_all_onfido_reports

Get all onfido reports given check id and user id

=cut

sub get_all_onfido_reports {
    my ($user_id, $check_id) = @_;
    my $dbic = BOM::Database::UserDB::rose_db()->dbic;
    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_hashref('SELECT * FROM users.get_onfido_reports(?::BIGINT, ?::TEXT)', 'id', undef, ($user_id, $check_id));
            });
    } catch ($e) {
        warn "Fail to get Onfido report from DB: $e . Please check USER_ID $user_id and CHECK_ID $check_id";
    }
    return;
}

=head2 store_onfido_live_photo

Stores onfido live_photo into the DB

=cut

sub store_onfido_live_photo {
    my ($doc, $applicant_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_live_photo(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                    undef, $doc->id, $applicant_id, Date::Utility->new($doc->created_at)->datetime_yyyymmdd_hhmmss,
                    $doc->href, $doc->download_href, $doc->file_name, $doc->file_type, $doc->file_size,
                );
            });
    } catch ($e) {
        warn "Fail to store Onfido live_photo in DB: $e . Please check DOC_ID: " . $doc->id;
    }

    return;
}

=head2 update_check_pdf_status

Updates the given PDF check to the desired status.

It takes the following parameters:

=over 4

=item * C<$id> - id of the Onfido check (this should be a UUID so string)

=item * C<$pdf_status> - either `completed` or `failed`

=back

Returns C<undef>

=cut

sub update_check_pdf_status {
    my ($id, $pdf_status) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    $dbic->run(
        fixup => sub {
            $_->do('SELECT users.onfido_check_pdf_status_transition(?, ?::users.onfido_pdf_status)', undef, $id, $pdf_status,);
        });

    return undef;
}

=head2 get_pending_pdf_checks

Grabs pending PDF checks from the DB on a LIFO fashion.

It takes the following parameters

=over 4

=item * C<$limit> - an integer for the LIMIT of the query

=back

Returns an arrayref of PDF pending Onfido check ids.

=cut

sub get_pending_pdf_checks {
    my ($limit) = @_;

    return [] unless $limit;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    return $dbic->run(
        fixup => sub {
            $_->selectall_arrayref('SELECT id FROM users.get_pending_pdf_onfido_checks(?)', {Slice => {}}, $limit,);
        });
}

=head2 store_onfido_document

Stores onfido document into the DB

=cut

sub store_onfido_document {
    my ($doc, $applicant_id, $issuing_country, $type, $side) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        $dbic->run(
            fixup => sub {
                $_->do(
                    'select users.add_onfido_document(?::TEXT, ?::TEXT, ?::TIMESTAMP, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::INTEGER)',
                    undef,
                    $doc->id,
                    $applicant_id,
                    Date::Utility->new($doc->created_at)->datetime_yyyymmdd_hhmmss,
                    $doc->href,
                    $doc->download_href,
                    $type,
                    $side,
                    uc(country_code2code($issuing_country, 'alpha-2', 'alpha-3') // $issuing_country),
                    $doc->file_name,
                    $doc->file_type,
                    $doc->file_size,
                );
            });
    } catch ($e) {
        warn "Fail to store Onfido document in DB: $e . Please check DOC_ID: " . $doc->id;
    }

    return;
}

=head2 get_onfido_document

Retrieves onfido document into the DB.
Applicant_id is optional. Pass it only when you want to get document specific to the applicant_id

=cut

sub get_onfido_document {
    my ($user_id, $applicant_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_hashref('select * from users.get_onfido_documents(?::BIGINT, ?::TEXT)', 'id', {}, $user_id, $applicant_id,);
            });
    } catch ($e) {
        warn "Fail to retrieve Onfido document from db: $e . Please check USER_ID: $user_id ";
    }

    return;
}

=head2 get_onfido_live_photo

Retrieves onfido live_photos into the DB.
Applicant_id is optional. Pass it only when you want to get live_photos specific to the applicant_id

=cut

sub get_onfido_live_photo {
    my ($user_id, $applicant_id) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectall_hashref('select * from users.get_onfido_live_photos(?::BIGINT, ?::TEXT)', 'id', {}, $user_id, $applicant_id,);
            });
    } catch ($e) {
        warn "Fail to retrieve Onfido live_photos from db: $e . Please check USER_ID: $user_id ";
    }

    return;
}

=head2 get_latest_check

Gets the onfido latest check data for the given client.

It takes the following named params:

=over 4

=item * L<BOM::User::Client> the client itself

=back

Returns,
    a hashref with the following content, gathered from onfido latest check:
    C<user_applicant>, C<report_document_status>, C<report_document_sub_result>, C<user_check>

=cut

sub get_latest_check {
    my $client = shift;
    my $args   = shift;

    my $country_code               = uc($client->place_of_birth || $client->residence // '');
    my $report_document_sub_result = '';
    my $report_document_status     = '';
    my $user_check;
    my $user_applicant;

    try {
        $user_applicant = get_all_user_onfido_applicant($client->binary_user_id) if BOM::Config::Onfido::is_country_supported($country_code);
    } catch ($error) {
        $user_applicant = undef;
    }

    # if documents are there and we have onfido applicant then
    # check for onfido check status and inform accordingly
    if ($user_applicant) {
        if ($user_check = get_latest_onfido_check($client->binary_user_id, undef, 1, $args->{only_verified})) {
            if (my $check_id = $user_check->{id}) {
                my $report_check_result = $user_check->{result} // '';
                $report_document_status = $user_check->{status} // '';

                if ($report_check_result eq 'consider') {
                    my $user_reports = get_all_onfido_reports($client->binary_user_id, $check_id);

                    # check for document result as we have accepted documents
                    # manually so facial similarity is not accurate as client
                    # use to provide selfie while holding identity card
                    my $report_document = first { ($_->{api_name} // '') eq 'document' }
                        sort { Date::Utility->new($a->{created_at})->is_before(Date::Utility->new($b->{created_at})) ? 1 : 0 } values %$user_reports;
                    $report_document_sub_result = $report_document->{sub_result} // '';
                }
            }
        }
    }

    return {
        user_check                 => $user_check,
        user_applicant             => $user_applicant,
        report_document_status     => $report_document_status,
        report_document_sub_result => $report_document_sub_result,
    };
}

=head2 get_consider_reasons

Extracts from the last onfido report the possible reasons under a consider status.

The parsing is based on the Onfido official documentation 

https://documentation.onfido.com/#document-report-breakdown-reasoning

The breakdown field from the users.onfido_report table should store a structure like this (as beautified json):

    {
        "visual_authenticity": {
            "result": "consider",
            "breakdown": {
            "security_features": {
                "result": "clear",
                "properties": {}
            },
            "original_document_present": {
                "result": "consider",
                    "properties": {
                        "screenshot": "consider",
                        "scan": "clear",
                    }
                }
            }
        }   
    }

In the example above, the `visual_authenticity` breakdown has `consider` result.
Even though the sub-breakdown `security_features` is `clear`, the `original_document_present` sub-breakdown
has a `consider` status and that's enough to flag the whole breakdown as `consider`.
Furthermore, `original_document_present` has a reason noted in the `properties` section. The given
reason was `screenshot`. Just like a breakdown, one `consider` reason is good enough to flag
the whole sub-breakdown as `consider`.

Note, for the sake of brevity, we limited the example to one breakdown, but there are more and is not 
clear whether a specific breakdown will always be reported in this column, for general purposes
we will assume each breakdown/sub-breakdown is optional.

Takes the following arguments:

=over 4

=item * C<$client> - the given L<BOM::User::Client>

=back

Returns,
    an arrayref of possible reasons why the document has been rejected

=cut

sub get_consider_reasons {
    my $client = shift;
    my @reasons;

    if (my $onfido_check = get_latest_onfido_check($client->binary_user_id, undef, 1)) {
        if ($onfido_check->{status} eq 'complete' and $onfido_check->{result} eq 'consider') {
            my $onfido_reports = get_all_onfido_reports($client->binary_user_id, $onfido_check->{id});

            for my $report (values $onfido_reports->%*) {
                my $result = $report->{result} // '';
                next unless $result eq 'consider';

                # If the facial similarity is `consider` we directly inject the `selfie` reason.
                my $api_name = $report->{api_name} // '';
                push @reasons, 'selfie' if $api_name eq 'facial_similarity' || $api_name eq 'facial_similarity_photo';

                # For documents, scan the whole thing looking for `result` as `consider` or `unidentified`
                # We may also look for a `properties` hash, in this case we scan each value for `consider` or `unidentified`.
                next unless $api_name eq 'document';
                my $breakdown_payload = eval { decode_json_utf8($report->{breakdown} // '{}') };
                stats_inc('onfido.report.bogus_breakdown') unless defined $breakdown_payload;

                $breakdown_payload //= {};
                push @reasons, _extract_breakdown_reasons($breakdown_payload)->@*;
            }
        }
    }

    return [uniq @reasons];
}

=head2 get_rules_reasons

Performs checks based on our business rules upon the given Onfido check.

These rules may or may not take into account check result (consider/clear).

It takes the following arguments:

=over 4

=item * C<$client> - a L<BOM::User::Client> instance

=back

Returns an arrayref of rejection reasons.

=cut

sub get_rules_reasons {
    my $client  = shift;
    my $reasons = [];

    my ($provider) = $client->latest_poi_by();
    $provider //= '';

    push $reasons->@*, 'data_comparison.first_name' if $client->status->poi_name_mismatch && $provider eq 'onfido';

    push $reasons->@*, 'data_comparison.date_of_birth' if $client->status->poi_dob_mismatch && $provider eq 'onfido';

    return $reasons;
}

=head2 _extract_breakdown_reasons

Performs a recursive parsing of the breakdown JSON from Onfido.

Any result with `consider` or `unidentified` within a breakdown should be deeply scanned for 
possible detailed reasons.

Each `property` should be scanned for reasons extracting, we are looking for either
`consider` or `unidentified` again.

Each breakdown may have nested breakdowns which must apply the same rules and so we hit recursion.

It takes the following arguments:

=over 4

=item * C<payload> the original decoded json from the B<users.onfido_report> table, B<breakdown> field

=item * C<reasons> the resulting arrayref being carried over the recursion

=item * C<stack> the stack being carried over to feed the recursion

=back

Returns an arrayref of rejection reasons found.

=cut

sub _extract_breakdown_reasons {
    my ($payload, $reasons, $stack) = @_;

    $reasons //= [];

    $stack //= [map { ref($payload->{$_}) eq 'HASH' ? +{$payload->{$_}->%*, name => $_} : () } keys $payload->%*];

    return $reasons unless scalar $stack->@*;

    my $next_stack = [];

    for my $breakdown ($stack->@*) {
        my $name   = $breakdown->{name};
        my $result = $breakdown->{result} // '';

        # Special case null document numbers
        push $reasons->@*, 'data_validation.no_document_numbers' if $name eq 'data_validation.document_numbers' and not defined $breakdown->{result};

        # Standalone consider or unidentified reason
        next unless $result =~ /consider|unidentified/;
        push $reasons->@*, $name;

        # Analyze the `properties` hashref for detailed reasons
        my $properties = {};
        $properties = $breakdown->{properties} if ref($breakdown->{properties}) eq 'HASH';

        for my $property (keys $properties->%*) {
            my $property_result = $properties->{$property} // '';
            push $reasons->@*, join('.', $name, $property) if $property_result =~ /consider|unidentified/;
        }

        # Do the same scanning on the child breakdowns
        my $nested_breakdowns = {};
        $nested_breakdowns = $breakdown->{breakdown} if ref($breakdown->{breakdown}) eq 'HASH';

        push $next_stack->@*, map { +{$nested_breakdowns->{$_}->%*, name => join('.', $name, $_)} } keys $nested_breakdowns->%*;
    }

    return _extract_breakdown_reasons($payload, $reasons, $next_stack);
}

=head2 submissions_left

Returns the submissions left for the client.

It takes the following arguments:

=over 4

=item * L<BOM::User::Client> the client itself

=back

Returns,
    an integer representing the submissions left for the user involved.

=cut

sub submissions_left {
    my $client  = shift;
    my $country = $client->residence;

    my $redis            = BOM::Config::Redis::redis_events();
    my $request_per_user = $redis->get(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id) // 0;
    my $submissions_left = limit_per_user($country) - $request_per_user;
    return $submissions_left;
}

=head2 submissions_reset_at

Returns a timestamp for when the onfido submission counter is expired
or undef if the redis key is not set

It takes the following arguments:

=over 4

=item * L<BOM::User::Client> the client itself

=back

Returns,
    a L<Date::Utility> that indicates when the user will have more onfido submissions available
    or undef if the redis key is not set

=cut

sub submissions_reset_at {
    my $client = shift;
    my $redis  = BOM::Config::Redis::redis_events();
    my $ttl    = $redis->ttl(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id);
    return undef if $ttl < 0;

    my $date = Date::Utility->new(time + $ttl);
    return $date;
}

=head2 limit_per_user

Provides a central point for onfido resubmissions limit per user in the specified
timeframe.

Returns,
    an integer representing the onfido submission requests allowed per user

=cut

sub limit_per_user {
    my $country = shift;

    return BOM::Platform::Utility::has_idv(('country' => $country)) ? 1 : 2;
}

=head2 timeout_per_user

Provides a central point for onfido resubmissions counter timeout in seconds.

Returns,
    an integer representing the seconds needed to expire the onfido counter per user.

=cut

sub timeout_per_user {
    return $ENV{ONFIDO_REQUEST_PER_USER_TIMEOUT} // 15 * 24 * 60 * 60;    # 15 days
}

=head2 reported_properties

Returns the client document's detected properties, from the last Onfido check, as hashref.

It takes the following arguments:

=over 4

=item * C<$client> - the L<BOM::User::Client> instance.

=back

Returns a hashref containing detected document properties.

=cut

sub reported_properties {
    my ($client) = @_;
    my $check    = get_latest_onfido_check($client->binary_user_id, undef, 1) || return {};
    my $check_id = $check->{id}                                               || return {};

    my ($report)   = grep { $_->{api_name} eq 'document' } values get_all_onfido_reports($client->binary_user_id, $check_id)->%*;
    my $properties = decode_json_utf8($report->{properties} // '{}');
    my $fields     = [qw/first_name last_name date_of_birth/];

    return +{map { defined $properties->{$_} ? ($_ => $properties->{$_}) : () } $fields->@*};
}

=head2 update_full_name_from_reported_properties

Compares the client document's detected properties, from the last Onfido check,
with the client's first name and last name and updates this data if there are any differences.
In case the first or last name are longer than 50 characters we find the last space within the first 50 characters and then trim the name to avoid errors retrieving the report

=over 4

=item * C<$client> - the L<BOM::User::Client> instance.

=back

Returns 1 on success or 0 if first name or last name is missing on reported properties.

=cut

sub update_full_name_from_reported_properties {
    my ($client) = @_;
    my $properties = reported_properties($client);

    return 0 unless $properties->{first_name} && $properties->{last_name};

    my $first_name_client = lc($client->first_name);
    my $last_name_client  = lc($client->last_name);
    my $first_name_report = lc($properties->{first_name});
    my $last_name_report  = lc($properties->{last_name});

    if ($first_name_client ne $first_name_report) {
        if (length($first_name_report) > 50) {
            my $last_space_index = rindex(substr($first_name_report, 0, 50), ' ');
            $first_name_report = substr($first_name_report, 0, $last_space_index) if $last_space_index != -1;
        }

        $client->first_name(join(" ", map { ucfirst($_) } split(/\s+/, $first_name_report)));
    }

    if ($last_name_client ne $last_name_report) {
        if (length($last_name_report) > 50) {
            my $last_space_index = rindex(substr($last_name_report, 0, 50), ' ');
            $last_name_report = substr($last_name_report, 0, $last_space_index) if $last_space_index != -1;
        }

        $client->last_name(join(" ", map { ucfirst($_) } split(/\s+/, $last_name_report)));
    }
    $client->save;

    return 1;
}

=head2 ready_for_authentication

Fires the infamous event to perform the applicant check request.

This function will also take care of counter increasing and everything
the frontend may need to properly render the POI page.

It takes:

=over 4

=item * C<$client> - a client instance

=item * C<$args> - an arrayref of arguments, we are particularly interested in:

=over 4

=item * C<documents> - an arrayref Onfido documents ids (optional)

=back

=back

Returns C<1>.

=cut

sub ready_for_authentication {
    my ($client, $args) = @_;
    my $redis = BOM::Config::Redis::redis_events();

    return 0 unless BOM::User::Onfido::submissions_left($client) > 0;

    unless ($redis->set(ONFIDO_REQUEST_PENDING_PREFIX . $client->binary_user_id, 1, 'NX', 'EX', ONFIDO_REQUEST_PENDING_TTL)) {
        # this should not happen as we'd expect the frontend to block further Onfido requests
        $log->warnf('Unexpected Onfido request when pending flag is still alive, user: %d', $client->binary_user_id);
        return 0;
    }

    my $user_applicant = get_user_onfido_applicant($client->binary_user_id);

    unless ($user_applicant->{id}) {
        $log->warnf('attempted ready_for_authentication emission without an applicant? user: %d', $client->binary_user_id);
        stats_inc('onfido.ready_for_authentication.no_applicant');
        return 0;
    }

    $redis->multi;
    $redis->incr(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id);
    $redis->expire(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id, timeout_per_user());
    $redis->exec;

    my $documents  = $args->{documents};
    my $staff_name = $args->{staff_name};

    BOM::Platform::Event::Emitter::emit(
        ready_for_authentication => {
            loginid      => $client->loginid,
            applicant_id => $user_applicant->{id},
            defined $documents  ? (documents  => $documents)  : (),
            defined $staff_name ? (staff_name => $staff_name) : (),
        });

    return 1;
}

=head2 pending_request

Determines whether there is a pending Onfido request.

It takes the following arguments:

=over 4

=item * C<$user_id> - the binary user id we are dealing with

=back

Returns a bool scalar.

=cut

sub pending_request {
    my ($user_id) = @_;

    my $redis = BOM::Config::Redis::redis_events();

    return ($redis->get(ONFIDO_REQUEST_PENDING_PREFIX . $user_id) // 0) > 0;
}

=head2 maybe_pending

Use this function to return the `pending` status for Onfido.

Some scenarios may cancel the `pending` and would yield a `none` instead.

It takes the following:

=over 4

=item * C<$client> - the instance of L<BOM::User::Client>

=back

Returns either C<pending> or C<none>

=cut

sub maybe_pending {
    my ($client) = @_;

    my $country_code = uc($client->place_of_birth || $client->residence // '');

    return 'pending' if BOM::Config::Onfido::is_country_supported($country_code);

    return 'none';
}

=head2 applicant_info

Gets the current client applicant info needed by `applicant_create`` and `applicant_update`
Onfido API endpoints.

It takes the following:

=over 4

=item * C<$client> - the instance of L<BOM::User::Client>

=item * C<$country> - (optional) 2 letters country.

=back

A hashref compatible with applicant create and applicant update endpoints. https://documentation.onfido.com/#applicant-object

=cut

sub applicant_info {
    my ($client, $country) = @_;

    my $residence = uc(country_code2code($client->residence, 'alpha-2', 'alpha-3'));

    $country //= uc($client->residence || $client->place_of_birth);

    my $details = {
        (map { $_ => $client->$_ } qw(first_name last_name email)),
        dob => $client->date_of_birth,
    };

    # Add address info if the required fields not empty
    $details->{address} = {
        building_number => $client->address_line_1,
        street          => $client->address_line_2 // $client->address_line_1,
        town            => $client->address_city,
        state           => $client->address_state,
        postcode        => $client->address_postcode,
        country         => uc(country_code2code($country, 'alpha-2', 'alpha-3')),
        }
        if all { length $client->$_ } ONFIDO_ADDRESS_REQUIRED_FIELDS;

    $details->{location} = {
        country_of_residence => $residence,
    };

    return $details;
}

=head2 is_available

Checks if Onfido service is available for the client

It takes the following params as a hashref:

=over 4

=item * C<client> a L<BOM::User::Client> instance.

=item * C<country> (optional) 2-letter country code.

=back

Returns,
    1 if Onfido is available for the client
    0 if Onfido is not available for the client


Onfido is available for the client if the Onfido service is enabled and:
    - has Onfido submissions left

=cut

sub is_available {
    my $args         = shift;
    my $client       = $args->{client};
    my $country_code = $args->{country};

    return 0 if is_onfido_disallowed($args);

    return 0 unless !$country_code || BOM::Config::Onfido::is_country_supported($country_code);

    return BOM::User::Onfido::submissions_left($client) > 0;
}

=head2 supported_documents

Gets the supported Onfido document types for the provided country.

It takes the following parameter:

=over 4

=item * C<country> 2-letter country code.

=back

Returns a hashref containing the information for each document type:

=over 4

=item * C<display_name> - document type display name.

=back

=cut

sub supported_documents {
    my $country_code = shift;

    return {map { _onfido_doc_type($_) } BOM::Config::Onfido::supported_documents_for_country($country_code)->@*};
}

=head2 _onfido_doc_type

Process the Onfido doc types given into the hash form expected by the api schema response,
since Onfido config provides a flat list of doc types it's somewhat complicated to give it
the conforming structure.

It takes the following parameter:

=over 4

=item * C<$doc_type> - the given onfido doc type

=back

Returns a single element hash as:

( $snake_case_key => {
    display_name => $doc_type,
})

=cut

sub _onfido_doc_type {
    my ($doc_type) = $_;
    my $snake_case_key = lc $doc_type =~ s/\s+/_/rg;

    return (
        $snake_case_key => {
            display_name => $doc_type,
        });
}

=head2 is_onfido_disallowed

Checks whether client is allowed to verify their identity via Onfido based on some business rules.

=over 4

=item * C<client> a L<BOM::User::Client> instance.

=item * C<landing_company> (optional) landing company. Default: client's landing company.

=back

Returns 1 if Onfido is disallowed, 0 otherwise.

=cut

sub is_onfido_disallowed {
    my $args = shift;
    my ($client, $landing_company) = @{$args}{qw/client landing_company/};

    my $lc = $landing_company ? LandingCompany::Registry->by_name($landing_company) : $client->landing_company;

    return 1 unless any { $_ eq 'onfido' } $lc->allowed_poi_providers->@*;

    return 1 if $client->status->unwelcome;

    my $poi_status = $args->{landing_company} ? $client->get_poi_status_jurisdiction($args) : $client->get_poi_status($args);
    return 1 if $client->status->age_verification && $poi_status eq 'verified';

    return 0;
}

1;
