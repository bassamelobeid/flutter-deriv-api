use strict;
use warnings;
use Test::More;
use BOM::Backoffice::FileUpload;
use Test::MockObject;

$ENV{CONTENT_LENGTH} = 10000;

subtest 'is_post_request' => sub {
    my $cgi = Test::MockObject->new();
    $cgi->set_always('request_method', 'POST');

    # Now you can use $cgi in your tests
    ok(BOM::Backoffice::FileUpload::is_post_request($cgi), 'POST request should return true');

    $cgi->set_always('request_method', 'GET');
    ok(!BOM::Backoffice::FileUpload::is_post_request($cgi), 'GET request should return false');
};

subtest 'get_batch_file' => sub {
    my $file = ['test.csv'];
    is(BOM::Backoffice::FileUpload::get_batch_file($file), 'test.csv', 'Should return the first file in the array');

    $file = 'test.csv';
    is(BOM::Backoffice::FileUpload::get_batch_file($file), 'test.csv', 'Should return the file as it is');
};

subtest 'validate_file' => sub {
    my $file = 'test.csv';
    ok(!BOM::Backoffice::FileUpload::validate_file($file), 'CSV file should pass validation');

    $file = 'test.txt';
    like(BOM::Backoffice::FileUpload::validate_file($file), qr/only csv files allowed/, 'Non-csv file should not pass validation');

    $ENV{CONTENT_LENGTH} = BOM::Backoffice::FileUpload::DOCUMENT_SIZE_LIMIT_IN_BYTES + 1;
    $file = 'test.csv';
    like(BOM::Backoffice::FileUpload::validate_file($file), qr/is too large/, 'File larger than limit should not pass validation');
};

done_testing();
