package BOM::Backoffice::Script::DocumentUpload;

use warnings;
use strict;

use Try::Tiny;
use Path::Tiny;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;

use constant UPLOAD_TIMEOUT => 120;

sub new {
    my ($class, %args) = @_;

    my $config = delete $args{config};

    # TODO: unify config keys across different s3 configs
    my $self = {
        config => {
            access_key => $config->{aws_access_key_id}     // $config->{access_key},
            secret_key => $config->{aws_secret_access_key} // $config->{secret_key},
            region     => $config->{region}                // 'ap-southeast-1',
            bucket     => $config->{aws_bucket}            // $config->{bucket},
        }};

    return bless $self, $class;
}

sub get_s3_url {
    my ($self, $file_name, $expiry) = @_;

    $expiry //= 600;    # default expiry is 10 minutes

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_name;

    return $self->_get_generator($expiry)->generate_url('GET', $self->{config}->{bucket} . "/$file_name", {});
}

sub upload {
    my ($self, $original_filename, $file_path, $checksum) = @_;

    my $file = path($file_path);

    die 'Unable to read the upload file handle' unless $file->exists;

    my $s3 = Net::Async::Webservice::S3->new(
        access_key => $self->{config}->{access_key},
        secret_key => $self->{config}->{secret_key},
        bucket     => $self->{config}->{bucket},
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

sub _get_generator {
    my ($self, $expiry) = @_;

    return $self->{generator} //= Amazon::S3::SignedURLGenerator->new(
        aws_access_key_id     => $self->{config}->{access_key},
        aws_secret_access_key => $self->{config}->{secret_key},
        prefix                => 'https://s3-' . $self->{config}->{region} . '.amazonaws.com/',
        expires               => $expiry,
    );
}

1;
