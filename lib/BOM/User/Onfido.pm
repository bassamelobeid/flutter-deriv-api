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
use List::Util qw(first);

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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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
    } catch {
        my $e = $@;
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

1;
