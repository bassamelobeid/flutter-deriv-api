use warnings;
use strict;

no warnings qw(redefine);

use Test::More;

BEGIN {
    *CORE::GLOBAL::time = sub { return 19 };
}

my $config = {
    aws_access_key_id     => 'fake_access_key',
    aws_secret_access_key => 'fake_secret_key',
    aws_region            => 'fake_region',
    aws_bucket            => 'fake_bucket',
};

use BOM::Platform::S3Client;

my $s3_upload = BOM::Platform::S3Client->new($config);

subtest 'get_s3_url should return a valid s3 URL' => sub {
    my $file_name = 'fake_file';
    my $s3_url    = $s3_upload->get_s3_url($file_name);
    my $expiry    = 619;                                  # 10 minutes
    like $s3_url, qr(https://s3-fake_region.amazonaws.com/fake_bucket/fake_file\?Signature=.*&Expires=$expiry&AWSAccessKeyId=fake_access_key),
        'S3 URL is correct';
};

done_testing();
