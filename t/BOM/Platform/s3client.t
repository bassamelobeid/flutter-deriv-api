use strict;
use warnings;
use Test::More;
use BOM::Platform::S3Client;
my $s3 = BOM::Platform::S3Client->new({
    aws_bucket            => 'test_bucket',
    aws_region            => 'test_region',
    aws_access_key_id     => 'test_id',
    aws_secret_access_key => 'test_access_key',
});

like($s3->get_s3_url("testfile.txt"), qr{https://s3-test_region.amazonaws.com}, 'In general url should include region');
$s3 = BOM::Platform::S3Client->new({
    aws_bucket            => 'test_bucket',
    aws_region            => 'us-east-1',
    aws_access_key_id     => 'test_id',
    aws_secret_access_key => 'test_access_key',
});
like($s3->get_s3_url("testfile.txt"), qr{https://s3.amazonaws.com}, 'but if region is us-east-1, the url should not include it');

done_testing();
