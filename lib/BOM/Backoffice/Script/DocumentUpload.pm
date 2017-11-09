package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use Digest::SHA qw/hmac_sha1_base64 sha1_hex/;
use URI::Escape;
use File::Slurp;
use Date::Utility;
use DateTime;

use Amazon::S3;

use BOM::Backoffice::Config;

my $document_auth_s3 = BOM::Backoffice::Config::config->{document_auth_s3};

my $access_key = $document_auth_s3->{access_key};
my $secret_key = $document_auth_s3->{secret_key};
my $region     = $document_auth_s3->{region};
my $bucket     = $document_auth_s3->{bucket};

sub get_s3_url {
    my $file_path = shift;

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_path;

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
        retry                 => 1,
        timeout               => 60
    });

    my $s3_bucket = $s3->bucket($bucket) or die 'Could not retrieve the requested s3 bucket';
    my $file = read_file($original_filename, binmode => ':raw') or die "Unable to read file: $original_filename";

    $s3_bucket->add_key($filename, $file) or die 'Unable to upload the file to s3.';

    return sha1_hex($file);
}

sub get_document_age {
    my $timestamp = Date::Utility->new(shift);

    my $now = DateTime->now;

    return $now->delta_days(
        DateTime->new(
            year  => $timestamp->year,
            month => $timestamp->month,
            day   => $timestamp->day_of_month,
        ))->delta_days();
}

1;
