use warnings;
use strict;

no warnings qw(redefine);

use Test::More;

use BOM::Backoffice::Config;

BEGIN {
    *BOM::Backoffice::Config::config = sub {
        return {
            document_auth_s3 => {
                access_key => 'fake_access_key',
                secret_key => 'fake_secret_key',
                region     => 'fake_region',
                bucket     => 'fake_bucket',
            }};
    };
    *CORE::GLOBAL::time = sub { return 19 };
}

use BOM::Backoffice::Script::DocumentUpload;

subtest 'get_s3_url should return a valid s3 URL' => sub {
    my $file_name = 'fake_file';
    my $s3_url    = BOM::Backoffice::Script::DocumentUpload::get_s3_url($file_name);
    my $expiry    = 619;                                                               # 10 minutes
    like $s3_url, qr(https://s3-fake_region.amazonaws.com/fake_bucket/fake_file\?Signature=.*&Expires=$expiry&AWSAccessKeyId=fake_access_key),
        'S3 URL is correct';
};

done_testing();
