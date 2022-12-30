use warnings;
use strict;
use Test::MockModule;
use Future::Utils;
use Test::Fatal;

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

subtest 'binary_upload test' => sub {
    my $s3 = Test::MockModule->new('Net::Async::Webservice::S3');
    my $response;
    my $failure;
    $s3->mock(
        'put_object',
        sub {
            if ($failure) {
                return Future->fail($failure);
            }
            return Future->done($response);
        });

    my $original_filename;
    my $binary_file = 'test';
    my $checksum    = 'test';

    my $result = exception { $s3_upload->upload_binary($original_filename, $binary_file, $checksum) };

    ok $result =~ m/You need to specify a filename/, 'Test for filename missing';

    $original_filename = 'test';
    $response          = 'fail';
    $result            = $s3_upload->upload_binary($original_filename, $binary_file, $checksum);

    my $e = exception { $result->get };

    ok $e =~ m/Checksum/, 'Test for Checksum mismatch';

    $response = '"test"';
    $result   = $s3_upload->upload_binary($original_filename, $binary_file, $checksum);

    is $result->get, $original_filename, 'Original filename is returned';

    $failure = 'failed badly';
    $result  = $s3_upload->upload_binary($original_filename, $binary_file, $checksum);

    $e = exception { $result->get };

    ok $e =~ m/Upload failed.*failed badly/, 'Test for future fail';

};

done_testing();
