package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use Digest::SHA qw/hmac_sha1_base64/;
use URI::Escape;
use File::Slurp;

use Amazon::S3;

use BOM::Backoffice::Config;

my $document_auth_s3 = BOM::Backoffice::Config::config->{document_auth_s3};

my $access_key = $document_auth_s3->{access_key};
my $secret_key = $document_auth_s3->{secret_key};
my $region     = $document_auth_s3->{region};
my $bucket     = $document_auth_s3->{bucket};

sub get_s3_url {
    my $file_path = shift;

    my $expires_in = time + 60 * 5;
    my $method     = 'GET';

    my $signature = hmac_sha1_base64("$method\n\n\n$expires_in\n/$bucket/$file_path", $secret_key);

    while (length($signature) % 4) {
        $signature .= '=';
    }

    $access_key = uri_escape($access_key);
    $signature  = uri_escape($signature);

    my $query = "AWSAccessKeyId=$access_key&Expires=$expires_in&Signature=$signature";

    return "https://s3-$region.amazonaws.com/$bucket/$file_path?$query";
}

sub upload {
    my ($filename, $original_filename) = @_;

    my $s3 = Amazon::S3->new({
        aws_access_key_id     => $access_key,
        aws_secret_access_key => $secret_key,
        retry                 => 1
    });

    my $s3_bucket = $s3->bucket($bucket);
    my $file = read_file($original_filename, binmode => ':raw');

    $s3_bucket->add_key($filename, $file);

    return;
}

1;
