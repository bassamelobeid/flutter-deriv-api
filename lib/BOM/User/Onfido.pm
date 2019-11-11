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
    }
    catch {
        my $e = $@;
        die "Fail to store Onfido applicant in DB: $e . Please check APPLICANT_ID: " . $applicant->id;
    };

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
                my $sth = $_->selectrow_hashref('select * from users.get_onfido_applicant(?::BIGINT)', undef, $user_id,);
            });
    }
    catch {
        my $e = $@;
        die "Fail to get Onfido applicant in DB: $e . Please check USER_ID: $user_id";
    };

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
    }
    catch {
        my $e = $@;
        die "Fail to get Onfido applicant in DB: $e . Please check USER_ID: $user_id";
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to store Onfido check in DB: $e . Please check CHECK_ID: " . $check->id;
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to update Onfido check in DB: $e . Please check CHECK_ID: " . $check->id;
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to store Onfido report in DB: $e . Please check REPORT_ID: " . $report->id;
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to store Onfido live_photo in DB: $e . Please check DOC_ID: " . $doc->id;
    };

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
                    uc(country_code2code($client_pob, 'alpha-2', 'alpha-3')),
                    $doc->file_name,
                    $doc->file_type,
                    $doc->file_size,
                );
            });
    }
    catch {
        my $e = $@;
        warn "Fail to store Onfido document in DB: $e . Please check DOC_ID: " . $doc->id;
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to retrieve Onfido document from db: $e . Please check USER_ID: $user_id ";
    };

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
    }
    catch {
        my $e = $@;
        warn "Fail to retrieve Onfido live_photos from db: $e . Please check USER_ID: $user_id ";
    };

    return;
}

1;
