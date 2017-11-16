package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use File::Slurp;
use Amazon::S3::SignedURLGenerator;
use Amazon::S3;

use BOM::Backoffice::Config;

my $document_auth_s3 = BOM::Backoffice::Config::config->{document_auth_s3};

my $access_key = $document_auth_s3->{access_key};
my $secret_key = $document_auth_s3->{secret_key};
my $region     = $document_auth_s3->{region};
my $bucket     = $document_auth_s3->{bucket};

my $generator = Amazon::S3::SignedURLGenerator->new(
    aws_access_key_id     => $access_key,
    aws_secret_access_key => $secret_key,
    prefix => "https://s3-$region.amazonaws.com/",
    expires => 600, # 10 minutes
);

sub get_s3_url {
    my $file_name = shift;

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_name;

    return $generator->generate_url('GET', "$bucket/$file_name", {});
}

sub upload {
    my ($filename, $original_filename) = @_;

    my $s3 = Amazon::S3->new({
        aws_access_key_id     => $access_key,
        aws_secret_access_key => $secret_key,
        retry                 => 1,
        timeout               => 60
    });

    my $s3_bucket = $s3->bucket($bucket) or die 'Could not retrieve the requested s3 bucket';
    my $file = read_file($original_filename, binmode => ':raw') or die "Unable to read file: $original_filename";

    $s3_bucket->add_key($filename, $file) or die 'Unable to upload the file to s3.';

    return sha1_hex($file);
}

1;
