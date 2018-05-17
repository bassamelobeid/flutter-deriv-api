package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use Try::Tiny;
use Path::Tiny;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;

use BOM::Backoffice::Config;

use constant UPLOAD_TIMEOUT => 120;

my ($document_auth_s3, $access_key, $secret_key, $region, $bucket);

# allow setting alternate S3 configuration via e.g.
# `use DocumentUpload -config => BOM::Platform::Config::third_party->{alt_s3_config};`
# XXX: temporary until deeper refactor of S3 upload is done
sub import {
    my (undef, %args) = @_;    # called as DocumentUpload->import() via `use`

    $document_auth_s3 = delete $args{'-config'} || BOM::Backoffice::Config::config()->{document_auth_s3};

    # TODO: unify config keys across different s3 configs
    $access_key = $document_auth_s3->{aws_access_key_id}     // $document_auth_s3->{access_key};
    $secret_key = $document_auth_s3->{aws_secret_access_key} // $document_auth_s3->{secret_key};
    $region     = $document_auth_s3->{region}                // 'ap-southeast-1';
    $bucket     = $document_auth_s3->{aws_bucket}            // $document_auth_s3->{bucket};

    return undef;
}

my $generator;

sub get_generator {
    my $expiry = shift;
    $generator //= Amazon::S3::SignedURLGenerator->new(
        aws_access_key_id     => $access_key,
        aws_secret_access_key => $secret_key,
        prefix                => "https://s3-$region.amazonaws.com/",
        expires               => $expiry,
    );
    return $generator;
}

sub get_s3_url {
    my ($file_name, $expiry) = @_;

    $expiry //= 600;    # default expiry is 10 minutes

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_name;

    return get_generator($expiry)->generate_url('GET', "$bucket/$file_name", {});
}

sub upload {
    my ($original_filename, $file_path, $checksum) = @_;

    my $file = path($file_path);

    die 'Unable to read the upload file handle' unless $file->exists;

    my $s3 = Net::Async::Webservice::S3->new(
        access_key => $access_key,
        secret_key => $secret_key,
        bucket     => $bucket,
        timeout    => UPLOAD_TIMEOUT,
    );

    my $loop = IO::Async::Loop->new;
    $loop->add($s3);

    my $etag;
    try {
        ($etag) = $s3->put_object(
            key   => $original_filename,
            value => $file->slurp,
            meta  => {checksum => $checksum},
        )->get;
    }
    catch {
        die "Upload Error: " . shift;
    };

    return $etag =~ s/"//gr;
}

1;
