use strict;
use warnings;
use Test::More;
use Test::MockModule;

require_ok('BOM::API::Payment::Metric');

my @test_cases = ({
        type     => 'validate',
        response => {
            allowed => 1,
        },
        expected_value => 'approve',
    },
    {
        type     => 'validate',
        response => {
            allowed => 0,
        },
        expected_value => 'reject',
    },
    {
        type     => '',
        response => {
            status => 200,
        },
        expected_value => 'success',
    },
    {
        type     => '',
        response => {
            status => 400,
        },
        expected_value => 'failure',
    },
    {
        type     => '',
        response => {
            status => 500,
        },
        expected_value => 'failure',
    },
    {
        type           => '',
        response       => {},
        expected_value => '',
    });

my $mocked_datadog = Test::MockModule->new('BOM::API::Payment::Metric');
my @datadog_args;
my @stats_timing;
$mocked_datadog->mock('stats_inc',    sub { @datadog_args = @_ });
$mocked_datadog->mock('stats_timing', sub { @stats_timing = @_ });

subtest 'test datadog metric collection' => sub {
    foreach my $test_case (@test_cases) {
        BOM::API::Payment::Metric::collect_metric($test_case->{type}, $test_case->{response}, ['tag']);
        like($datadog_args[0], qr/$test_case->{expected_value}/, 'datadog should collect the correct metrics');
        @datadog_args = [];
    }
};

subtest 'test datadog metric collection with request_millisec' => sub {
    my $test_case = $test_cases[0];
    BOM::API::Payment::Metric::collect_metric($test_case->{type}, $test_case->{response}, ['tag'], 1234);
    is_deeply(
        \@stats_timing,
        ['bom.paymentapi.doughflow.request_time', 1234, {tags => ["request_type:validate"]}],
        'datadog should collect the request_millisec'
    );
};

done_testing();
