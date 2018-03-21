package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use Try::Tiny;
use File::Slurp;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;

use BOM::Backoffice::Config;

use constant UPLOAD_TIMEOUT => 120;

my $document_auth_s3 = BOM::Backoffice::Config::config->{document_auth_s3};

my $access_key = $document_auth_s3->{access_key};
my $secret_key = $document_auth_s3->{secret_key};
my $region     = $document_auth_s3->{region};
my $bucket     = $document_auth_s3->{bucket};

my $generator;

sub get_generator {
    $generator //= Amazon::S3::SignedURLGenerator->new(
        aws_access_key_id     => $access_key,
        aws_secret_access_key => $secret_key,
        prefix                => "https://s3-$region.amazonaws.com/",
        expires               => 600,                                   # 10 minutes
    );
    return $generator;
}

sub get_s3_url {
    my $file_name = shift;

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_name;

    return get_generator()->generate_url('GET', "$bucket/$file_name", {});
}

sub upload {
    my ($original_filename, $upload_file_handle, $checksum) = @_;

    die 'Unable to read the upload file handle' unless tell($upload_file_handle) != -1;

    my %config = %$document_auth_s3;
    delete $config{region};

    my $s3 = Net::Async::Webservice::S3->new(
        %config,
        timeout => UPLOAD_TIMEOUT,
    );

    my $loop = IO::Async::Loop->new;
    $loop->add($s3);

    my $etag;
    try {
        ($etag) = $s3->put_object(
            key   => $original_filename,
            value => read_file($upload_file_handle),
            meta  => {checksum => $checksum},
        )->get;
    }
    catch {
        die "Upload Error: " . shift;
    };

    return $etag =~ s/"//gr;
}

1;
