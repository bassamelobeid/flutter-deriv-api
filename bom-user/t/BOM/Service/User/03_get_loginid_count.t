use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Service;
use BOM::Service::Helpers;

my $test_customer = BOM::Test::Customer->create(
    email_verified => 1,
    clients        => [{
            name        => 'VRTC',
            broker_code => 'VRTC',
        },
    ]);

is BOM::Service::Helpers::_get_loginid_count($test_customer->get_user_id()), 1, 'User has 1 client';

$test_customer->create_client(
    name        => 'CR1',
    broker_code => 'CR'
);

is BOM::Service::Helpers::_get_loginid_count($test_customer->get_user_id()), 2, 'User has 2 clients';

$test_customer->create_client(
    name        => 'CR2',
    broker_code => 'CR'
);

is BOM::Service::Helpers::_get_loginid_count($test_customer->get_user_id()), 3, 'User has 3 clients';

done_testing();

