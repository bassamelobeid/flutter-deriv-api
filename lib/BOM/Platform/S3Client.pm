package BOM::Platform::S3Client;

use strict;
use warnings;
use IO::Async::Loop;
use Net::Async::Webservice::S3;
use Amazon::S3::SignedURLGenerator;
use Fcntl 'SEEK_SET';
use File::stat;
use 5.010;

use constant {
    DEFAULT_UPLOAD_TIMEOUT => 120,
    DEFAULT_REGION         => 'ap-southeast-1',
    DEFAULT_EXPIRY         => 600,
};

sub new {
    my ($class, $config) = @_;
    die 'AWS/S3 keys are unavailable'
        unless $config->{aws_access_key_id}
        and $config->{aws_secret_access_key}
        and $config->{aws_bucket};

    $config->{timeout}    //= DEFAULT_UPLOAD_TIMEOUT;
    $config->{aws_region} //= DEFAULT_REGION;

    state %s3_services;
    my $s3_hash_key = sprintf("%s %s %s", $config->{aws_access_key_id}, $config->{aws_bucket}, $config->{aws_region});
    my $s3 = $s3_services{$s3_hash_key};
    unless ($s3) {
        $s3 = Net::Async::Webservice::S3->new(
            access_key => $config->{aws_access_key_id},
            secret_key => $config->{aws_secret_access_key},
            bucket     => $config->{aws_bucket},
            timeout    => $config->{timeout},
        );
        IO::Async::Loop->new->add($s3);
        $s3_services{$s3_hash_key} = $s3;
    }

    my $self = {
        config => $config,
        s3     => $s3,
    };

    return bless $self, $class;
}

sub get_s3_url {
    my ($self, $file_name, $expiry) = @_;

    $expiry //= DEFAULT_EXPIRY;    # default expiry is 10 minutes

    die 'Cannot get s3 url for the document because the file_name is missing' unless $file_name;

    return $self->_get_generator($expiry)->generate_url('GET', $self->{config}->{aws_bucket} . "/$file_name", {});
}

sub upload {
    my ($self, $original_filename, $file_path, $checksum) = @_;
    my $fh;
    open($fh, "<:raw", $file_path) or return Future->fail('Unable to read the upload file handle');    ## no critic (RequireBriefOpen)

    my $stat      = stat($fh);
    my $file_size = $stat->size;

    my $gen_chunks = sub {
        my ($pos, $len) = @_;
        sysseek($fh, $pos, SEEK_SET);
        my $buffer;
        return undef unless defined sysread($fh, $buffer, $len);
        return $buffer;
    };

    return $self->{s3}->put_object(
        key          => $original_filename,
        value        => $gen_chunks,
        value_length => $file_size,
        meta         => {checksum => $checksum},
        )->then(
        sub {
            my $result = shift;
            return Future->done($original_filename) if "\"$checksum\"" eq $result;
            return Future->fail("Checksum mismatch for: $original_filename");
        }
        )->else(
        sub {
            return Future->fail("Upload failed for $original_filename, error: " . shift);
        }
        )->on_ready(
        sub {
            close($fh);
        });
}

sub download {
    my ($self, $file) = @_;
    return $self->{s3}->get_object(key => $file);
}

sub _get_generator {
    my ($self, $expiry) = @_;

    return $self->{generator} //= Amazon::S3::SignedURLGenerator->new(
        aws_access_key_id     => $self->{config}->{aws_access_key_id},
        aws_secret_access_key => $self->{config}->{aws_secret_access_key},
        # Here we do a special process on `us-east-1` because as a default region, its url has no rigion part
        # Please refer to https://docs.aws.amazon.com/AmazonS3/latest/dev/UsingBucket.html#access-bucket-intro
        prefix => 'https://s3' . ($self->{config}->{aws_region} eq 'us-east-1' ? "" : '-' . $self->{config}{aws_region}) . '.amazonaws.com/',
        expires => $expiry,
    );
}

sub head_object {
    my ($self, $filename) = @_;
    return $self->{s3}->head_object(
        key => $filename,
    );
}

sub delete {
    my ($self, $filename) = @_;
    # s3 delete_object needs filename and bucket in HTTP request header
    return $self->{s3}->delete_object(
        key    => $filename,
        bucket => $self->{config}->{aws_bucket},
    );
}
1;
