package BOM::User::Onfido;

=head1 Description

This file handles all the Onfido related codes

=cut

use strict;
use warnings;

use BOM::Database::UserDB;
use Syntax::Keyword::Try;
use Date::Utility;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use Locale::Codes::Country qw(country_code2code);
use DataDog::DogStatsd::Helper qw(stats_inc);
use List::Util qw(first uniq);
use BOM::Config::Redis;

use constant ONFIDO_REQUEST_PER_USER_PREFIX => 'ONFIDO::REQUEST::PER::USER::';

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
                    undef,            $applicant->id, Date::Utility->new($applicant->created_at)->datetime_yyyymmdd_hhmmss,
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
                    $check->type,
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
    my ($user_id, $applicant_id, $limit) = @_;

    my $dbic = BOM::Database::UserDB::rose_db()->dbic;

    try {
        return $dbic->run(
            fixup => sub {
                $_->selectrow_hashref('SELECT * FROM users.get_onfido_checks(?::BIGINT, ?::TEXT, ?::BIGINT)', undef, $user_id, $applicant_id, $limit);
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

=head2 store_onfido_document

Stores onfido document into the DB

=cut

sub store_onfido_document {
    my ($doc, $applicant_id, $client_pob, $type, $side) = @_;

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
                    uc(country_code2code($client_pob, 'alpha-2', 'alpha-3') // ''),
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
    my $client                     = shift;
    my $report_document_sub_result = '';
    my $report_document_status     = '';
    my $user_check;
    my $user_applicant;

    try {
        $user_applicant = get_all_user_onfido_applicant($client->binary_user_id);
    } catch ($error) {
        $user_applicant = undef;
    }

    # if documents are there and we have onfido applicant then
    # check for onfido check status and inform accordingly
    if ($user_applicant) {
        if ($user_check = get_latest_onfido_check($client->binary_user_id, undef, 1)) {
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
                push @reasons, 'selfie' if $api_name eq 'facial_similarity';

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
    my $client           = shift;
    my $redis            = BOM::Config::Redis::redis_events();
    my $request_per_user = $redis->get(ONFIDO_REQUEST_PER_USER_PREFIX . $client->binary_user_id) // 0;
    my $submissions_left = limit_per_user() - $request_per_user;
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
    return $ENV{ONFIDO_REQUEST_PER_USER_LIMIT} // 3;
}

=head2 timeout_per_user

Provides a central point for onfido resubmissions counter timeout in seconds.

Returns,
    an integer representing the seconds needed to expire the onfido counter per user.

=cut

sub timeout_per_user {
    return $ENV{ONFIDO_REQUEST_PER_USER_TIMEOUT} // 15 * 24 * 60 * 60;    # 15 days
}

1;
