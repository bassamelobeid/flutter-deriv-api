use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Warnings qw(warning);
use Test::MockModule;
use DataDog::DogStatsd::Helper;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Event::Actions::Customerio;
use BOM::User;

my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @datadog_calls;
$mocked_datadog->mock('stats_inc', sub { push(@datadog_calls, \@_) });

my $mock_config = Test::MockModule->new('BOM::Config');
$mock_config->mock(
    'third_party',
    sub {
        return {
            customerio => {
                api_uri => 'http://dummy',
                site_id => 'dummy',
                api_key => 'dummy'
            }};
    });

BOM::Config::Runtime->instance->app_config->system->suspend->customerio(0);

subtest 'register_details Argument Validations' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test1@bin.com',
    });

    ok !BOM::Event::Actions::Customerio::register_details(), 'False result for empy args';
    ok !BOM::Event::Actions::Customerio::register_details({loginid => 'CR123456'}), 'False result for invalid loginid';
    ok !BOM::Event::Actions::Customerio::register_details({loginid => $test_client->loginid}), 'False result for a client without a user';

    my $user = BOM::User->create(
        email          => $test_client->email,
        password       => "hello",
        email_verified => 1,
    );
    $user->add_client($test_client);

    ok !BOM::Event::Actions::Customerio::register_details({loginid => $test_client->loginid}), 'False result if user has no email consent';
    is scalar(@datadog_calls), 0, 'No datadog calls yet';

    $user->update_email_fields(email_consent => 1);
    like(
        warning { BOM::Event::Actions::Customerio::register_details({loginid => $test_client->loginid}) },
        qr/Connection error/,
        'The expected warning is raised'
    );

    my @expected_datadog = (
        ['event.customerio.all', {tags => ['method:register_details']}],
        [
            'event.customerio.failure',
            {tags => ['method:register_details', 'error:Connection error', 'message:Can\'t connect: Name or service not known']},
        ],
    );
    is scalar(@datadog_calls), 2, 'Correct number of datadog calls';
    is_deeply \@datadog_calls, \@expected_datadog, 'Correct datadog tags';
    @datadog_calls = ();
};

subtest 'email_consent Argument Validations' => sub {
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test2@bin.com',
    });

    ok !BOM::Event::Actions::Customerio::email_consent(), 'False result for empy args';
    ok !BOM::Event::Actions::Customerio::email_consent({loginid => 'CR123456'}), 'False result for invalid loginid';
    ok !BOM::Event::Actions::Customerio::email_consent({loginid => $test_client->loginid}), 'False result for a client without user';

    my $user = BOM::User->create(
        email          => $test_client->email,
        password       => "hello",
        email_verified => 1,
    );
    $user->add_client($test_client);
    is scalar(@datadog_calls), 0, 'No datadog calls yet';

    like(
        warning { BOM::Event::Actions::Customerio::email_consent({loginid => $test_client->loginid}) },
        qr/Connection error/,
        'The expected warning is raised'
    );

    my @expected_datadog = (
        ['event.customerio.all', {tags => ['method:email_consent_delete']}],
        [
            'event.customerio.failure',
            {tags => ['method:email_consent_delete', 'error:Connection error', 'message:Can\'t connect: Name or service not known']},
        ],
    );
    is scalar(@datadog_calls), 2, 'Correct number of datadog calls';
    is_deeply \@datadog_calls, \@expected_datadog, 'Correct datadog tags - failures';
    @datadog_calls = ();

    $test_client->status->set('disabled', 1, 'test disabled');
    like(
        warning { BOM::Event::Actions::Customerio::email_consent({loginid => $test_client->loginid}) },
        qr/Connection error/,
        'The expected warning is raised'
    );
    is scalar(@datadog_calls), 2, 'DataDog called for disabled account';
    is_deeply \@datadog_calls, \@expected_datadog, 'Correct datadog tags - disabled account';
    @datadog_calls = ();

};

done_testing();
