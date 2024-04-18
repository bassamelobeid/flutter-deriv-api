use strict;
use warnings;
use Test::More;
use Test::MockModule;
use Test::MockObject;
use BOM::Backoffice::CustomSanctionScreening;
use JSON::MaybeUTF8 qw(:v1);

# Mock the BOM::Config::Redis module
my $redis_instance = Test::MockModule->new('RedisDB');
my $redis          = Test::MockModule->new('BOM::Config::Redis');

# Mock the Date::Utility module
my $date_utility_mock = Test::MockModule->new('Date::Utility');
my $today_date        = '2023-04-04';
$date_utility_mock->mock('today', sub { return {date => $today_date} });

# Mock the encode_json_utf8 function
my $json_data        = '{"date_uploaded":"2023-04-04","data":"test_data"}';
my $encode_json_mock = Test::MockModule->new('JSON');
$encode_json_mock->mock('encode_json_utf8', sub { return $json_data });

# Mock the log module
my $log_mock = Test::MockModule->new('Log::Any');
$log_mock->mock('warn', sub { });    # Suppress log warnings during tests

# Mock CGI object for testing file upload
my $cgi_mock = Test::MockObject->new();
$cgi_mock->fake_module('CGI');

my $csv_file_handle;

# Mock the Text::CSV module
my $csv_mock = Test::MockModule->new('Text::CSV');
my $csv_instance;

# Mock the upload method on the CGI object
$cgi_mock->mock(upload => sub { return \*DATA });

my $data = [{
        first_name    => 'John',
        last_name     => 'Doe',
        date_of_birth => '1990-01-01'
    },
    {
        first_name    => 'Jane',
        last_name     => 'Smith',
        date_of_birth => '1985-05-15'
    },
];

subtest 'Test save_custom_sanction_data_to_redis' => sub {
    $redis->mock('redis_replicated_write', sub { return $redis_instance });
    $redis->mock('del',                    sub { return 1 });
    $redis->mock('set',                    sub { return 'OK' });
    $date_utility_mock->mock('today', sub { return {date => $today_date} });
    my $expected_json_data =
        '{"date_uploaded":"2023-04-04","data":[{"first_name":"John","last_name":"Doe","date_of_birth":"1990-01-01"},{"first_name":"Jane","last_name":"Smith","date_of_birth":"1985-05-15"}]}';
    $encode_json_mock->mock('encode_json_utf8', sub { return $expected_json_data });
    BOM::Backoffice::CustomSanctionScreening::save_custom_sanction_data_to_redis($data);
    my $saved_data = decode_json_utf8($expected_json_data);
    is_deeply(
        $saved_data,
        {
            date_uploaded => $today_date,
            data          => $data
        },
        'Custom sanction data saved correctly to Redis'
    );
};

subtest 'Test save_custom_sanction_data_to_redis_fail' => sub {
    $redis->mock('redis_replicated_write', sub { return $redis_instance });
    $redis->mock('del',                    sub { return 1 });
    $redis->mock('set',                    sub { die 'Redis operation error' });
    my $log_mock = Test::MockModule->new('Log::Any');
    $log_mock->mock(
        'warn',
        sub {
            my ($self, $message) = @_;
            like($message, qr/Error occurred while saving custom sanction data to Redis/, "Expected warning message logged");
        });
    BOM::Backoffice::CustomSanctionScreening::save_custom_sanction_data_to_redis($data);
    ok(1, 'Function handled Redis operation error correctly');
};

subtest 'Test retrieve_custom_sanction_data_from_redis' => sub {
    my $expected_data = [{
            first_name    => 'John',
            last_name     => 'Doe',
            date_of_birth => '11-11-2001'
        },
        {
            first_name    => 'Jane',
            last_name     => 'Smith',
            date_of_birth => '11-11-2001'
        },
    ];
    $redis->mock('redis_replicated_write', sub { return $redis_instance });
    $redis_instance->mock(
        'get',
        sub {
            return encode_json_utf8($expected_data);
        });

    my $result = BOM::Backoffice::CustomSanctionScreening::retrieve_custom_sanction_data_from_redis();

    is_deeply($result, $expected_data, 'Retrieved custom sanction data matches expected data');
};

done_testing();

__DATA__
name,dob,country
John Doe,1990-01-01,USA
Jane Smith,1985-05-15,UK
