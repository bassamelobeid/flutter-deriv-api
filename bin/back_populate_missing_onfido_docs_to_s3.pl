#!/etc/rmg/bin/perl

use strict;
use warnings;

use YAML::XS qw(LoadFile Load);
use IO::Async::Loop;
use Future::AsyncAwait;
use Syntax::Keyword::Try;
use JSON::MaybeUTF8 qw(decode_json_utf8 encode_json_utf8);
use List::Util qw(min);
use BOM::User;
use BOM::User::Client;
use BOM::User::Onfido;
use BOM::Database::UserDB;
use BOM::Event::Services;
use BOM::Event::Services::Track;
use Getopt::Long;
use Log::Any qw($log);
use WebService::Async::Onfido;
use Path::Tiny qw(path);
use BOM::User;
use Locale::Codes::Country qw(country_code2code);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s'               => \my $log_level,
    'requests_per_minute=i' => \my $requests_per_minute,
    'filename=s'            => \my $file_name,
    'json_log_file=s'       => \my $json_log_file,
) or die;

die("--filename NAME is required\n") unless $file_name;

$log_level           ||= 'info';
$requests_per_minute ||= 30;
$json_log_file       ||= '/var/log/deriv/' . path($0)->basename . '.json.log';
Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $log_level,
    json_log_file => $json_log_file
);

=head2

This script will get a file as input argument contains list of loginids that have missed Onfido documents.
It will get applicant for each client then list of checks and download check's documents
and upload them to S3 so they will be accessible from Backoffice.

=cut

open(my $fh, "<", $file_name) or die "Can't open < $file_name: $!";    ## no critic (RequireBriefOpen)
my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);
$services->add_child(
    my $onfido = WebService::Async::Onfido->new(
        token               => BOM::Config::third_party()->{onfido}->{authorization_token},
        requests_per_minute => $requests_per_minute
    ));

# Mapping to convert our database entries to the 'side' parameter in the
# Onfido API
my %ONFIDO_DOCUMENT_SIDE_MAPPING = (
    front => 'front',
    back  => 'back',
    photo => 'photo',
);

while (my $loginid = <$fh>) {
    chomp $loginid;
    my $client = BOM::User::Client->new({loginid => $loginid});
    unless ($client) {
        $log->debugf("Can not initiate client with loginid %s", $loginid);
        next;
    }
    my $applicant = BOM::User::Onfido::get_user_onfido_applicant($client->binary_user_id);
    unless ($applicant) {
        $log->debugf("Can not find applicant for client %s", $loginid);
        next;
    }
    _store_onfido_data($applicant, $client)->get;
}

close $fh;

async sub _store_onfido_data {
    my ($applicant, $client) = @_;

    my $applicant_id = $applicant->{id};
    $applicant = await $onfido->applicant_get(applicant_id => $applicant_id);
    my @checks = await $applicant->checks->as_list;

    foreach my $check (@checks) {
        my @all_report = await $check->reports->as_list;
        await _store_applicant_documents($applicant_id, $client, \@all_report);
    }

}

=head2 _store_applicant_documents

Gets the client's documents from Onfido and store in DB

=cut

async sub _store_applicant_documents {
    my ($applicant_id, $client, $all_report) = @_;

    my @documents = await $onfido->document_list(applicant_id => $applicant_id)->as_list;

    my $existing_onfido_docs = BOM::User::Onfido::get_onfido_document($client->binary_user_id);

    foreach my $doc (@documents) {

        my $type = $doc->type;
        my $side = $doc->side;
        $side = $side && $ONFIDO_DOCUMENT_SIDE_MAPPING{$side} // 'front';
        $type = 'live_photo' if $side eq 'photo';

        unless ($existing_onfido_docs && $existing_onfido_docs->{$doc->id}) {
            $log->debugf('Insert document data for user %s and document id %s', $client->binary_user_id, $doc->id);

            BOM::User::Onfido::store_onfido_document($doc, $applicant_id, $client->place_of_birth, $type, $side);

            try {
                await _sync_onfido_bo_document({
                    type          => 'document',
                    document_id   => $doc->id,
                    client        => $client,
                    applicant_id  => $applicant_id,
                    onfido_result => $doc,
                    all_report    => $all_report
                });
            } catch ($e) {
                $log->errorf("Error in downloading document %s for client %s and sync document file : $e", $client->loginid, $doc->id);
            }
        }
    }

    my @live_photos            = await $onfido->photo_list(applicant_id => $applicant_id)->as_list;
    my $existing_onfido_photos = BOM::User::Onfido::get_onfido_live_photo($client->binary_user_id);

    foreach my $photo (@live_photos) {
        unless ($existing_onfido_photos && $existing_onfido_photos->{$photo->id}) {
            $log->debugf('Insert live photo data for user %s and document id %s', $client->binary_user_id, $photo->id);

            BOM::User::Onfido::store_onfido_live_photo($photo, $applicant_id);

            try {
                await _sync_onfido_bo_document({
                    type          => 'photo',
                    document_id   => $photo->id,
                    client        => $client,
                    applicant_id  => $applicant_id,
                    onfido_result => $photo,
                    all_report    => $all_report
                });
            } catch ($e) {
                $log->errorf("Error in downloading photo file %s for client %s and sync photo file : $e", $client->loginid, $photo->id);
            }

        }
    }

    return;
}

=head2 _sync_onfido_bo_document

Gets the client's documents from Onfido and upload to S3

=cut

async sub _sync_onfido_bo_document {
    my $args = shift;
    my ($type, $doc_id, $client, $applicant_id, $onfido_res, $all_report) =
        @{$args}{qw/type document_id client applicant_id onfido_result all_report/};

    my $s3_client = BOM::Platform::S3Client->new(BOM::Config::s3()->{document_auth});

    my $doc_type;
    my $page_type = '';
    my $image_blob;
    my $expiration_date;
    my $document_numbers;
    my @doc_ids;

    if ($type eq 'document') {
        $doc_type  = $onfido_res->type;
        $page_type = $onfido_res->side;
        for my $each_report (@{$all_report}) {
            if ($each_report->documents) {
                @doc_ids = grep { $_ && $_->{id} } @{$each_report->documents};
                my %all_ids = map { $_->{id} => 1 } @doc_ids;

                if (exists($all_ids{$doc_id})) {
                    ($expiration_date, $document_numbers) = @{$each_report->{properties}}{qw(date_of_expiry document_numbers)};
                    last;
                }
            }
        }
        $image_blob = await $onfido->download_document(
            applicant_id => $applicant_id,
            document_id  => $doc_id
        );
    } elsif ($type eq 'photo') {
        $doc_type   = 'photo';
        $image_blob = await $onfido->download_photo(
            applicant_id  => $applicant_id,
            live_photo_id => $doc_id
        );
    } else {
        die "Unsupported document type";
    }
    die "Invalid expiration date" if ($expiration_date
        && $expiration_date ne (eval { Date::Utility->new($expiration_date)->date_yyyymmdd } // ''));
    my $file_type = $onfido_res->file_type;

    my $fh           = File::Temp->new(DIR => '/var/lib/binary');
    my $tmp_filename = $fh->filename;
    print $fh $image_blob;
    seek $fh, 0, 0;
    my $file_checksum = Digest::MD5->new->addfile($fh)->hexdigest;
    close $fh;

    my $upload_info;
    my $s3_uploaded;
    my $file_id;
    my $new_file_name;
    my $doc_id_number;
    $doc_id_number = $document_numbers->[0]->{value} if $document_numbers;
    try {
        $upload_info = $client->db->dbic->run(
            ping => sub {
                $_->selectrow_hashref(
                    'SELECT * FROM betonmarkets.start_document_upload(?, ?, ?, ?, ?, ?, ?, ?)',
                    undef, $client->loginid, $doc_type, $file_type,
                    $expiration_date || undef,
                    $doc_id_number   || '',
                    $file_checksum, '', $page_type,
                );
            });

        unless ($upload_info) {
            $log->errorf("Document already exists for client %s", $client->loginid);
            return;
        }

        ($file_id, $new_file_name) = @{$upload_info}{qw/file_id file_name/};

        $log->debugf("Starting to upload file_id: $file_id to S3 ");
        $s3_uploaded = await $s3_client->upload($new_file_name, $tmp_filename, $file_checksum);
    } catch ($error) {
        local $log->context->{loginid}         = $client->loginid;
        local $log->context->{doc_type}        = $doc_type;
        local $log->context->{file_type}       = $file_type;
        local $log->context->{expiration_date} = $expiration_date;
        local $log->context->{doc_id_number}   = $doc_id_number;
        local $log->context->{file_checksum}   = $file_checksum;
        local $log->context->{page_type}       = $page_type;
        $log->errorf("Error in creating record in db and uploading Onfido document to S3 for %s : %s", $client->loginid, $error);
    };

    if ($s3_uploaded) {
        $log->debugf("Successfully uploaded file_id: $file_id to S3 ");
        try {
            my $finish_upload_result = $client->db->dbic->run(
                ping => sub {
                    $_->selectrow_array('SELECT * FROM betonmarkets.finish_document_upload(?)', undef, $file_id);
                });
            die "Db returned unexpected file_id on finish. Expected $file_id but got $finish_upload_result. Please check the record"
                unless $finish_upload_result == $file_id;

            my $document_info = _get_document_details(
                loginid => $client->loginid,
                file_id => $file_id
            );
            await BOM::Event::Services::Track::document_upload({
                loginid    => $client->loginid,
                properties => $document_info
            });
        } catch ($error) {
            $log->errorf("Error in updating db for %s : %s", $client->loginid, $error);
        };
    }

    return;
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
        } catch {
            die "An error occurred while getting document details ($file_id) from database for login ID $loginid.";
        };
        $doc;
    };
}

