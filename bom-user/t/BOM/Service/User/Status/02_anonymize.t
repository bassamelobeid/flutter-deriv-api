use strict;
use warnings;
use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockObject;
use Test::MockModule;
use BOM::Database::ClientDB;
use UUID::Tiny;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../../../lib";

use BOM::Service;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use UserServiceTestHelper;

my $dump_response = 0;

subtest 'simple virtual only customer' => sub {
    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        clients        => [{name => 'VRTC', broker_code => 'VRTC',}]);

    my $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_status',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},           'ok', 'call succeeded';
    is $response->{anonymize_status}, 0,    'not yet anonymized, virtual only customer';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_allowed',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},            'ok', 'call succeeded';
    is $response->{anonymize_allowed}, 1,    'anonymize is allowed, virtual only customer';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_user',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    my $expected = [sort ($customer->get_client_loginid('VRTC'))];
    is $response->{status}, 'ok', 'call succeeded';
    is_deeply [sort @{$response->{clients}}], $expected, 'user client ids are as expected';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_status',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},           'ok', 'call succeeded';
    is $response->{anonymize_status}, 1,    'user is anonymized';

};

subtest 'customer with real/virtual' => sub {

    # Create a mock module for BOM::Database::ClientDB
    my $mock = Test::MockModule->new("BOM::Database::ClientDB");

    # FOG DB doesn't exist and test will fail when its method is called so we will just mock it
    # for the test so that the anonymize_allowed method can return the expected value
    $mock->redefine(
        new => sub {
            my ($class, $params) = @_;
            if ($params->{broker_code} eq 'FOG') {
                my $db = Test::MockObject->new();
                $db->mock(
                    db => sub {
                        my $dbic = Test::MockObject->new();
                        $dbic->mock(
                            dbic => sub {
                                my $run = Test::MockObject->new();
                                $run->mock(
                                    run => sub {
                                        return {ck_user_valid_to_anonymize => 0};
                                    });
                                return $run;
                            });
                        return $dbic;
                    });
                return $db;
            } else {
                return $mock->original('new')->(@_);
            }
        });

    my $customer = BOM::Test::Customer->create(
        email_verified => 1,
        clients        => [{
                name        => 'VRTC',
                broker_code => 'VRTC'
            },
            {
                name        => 'CR',
                broker_code => 'CR'
            }]);

    my $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_status',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},           'ok', 'call succeeded';
    is $response->{anonymize_status}, 0,    'not yet anonymized';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_allowed',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},            'ok', 'call succeeded';
    is $response->{anonymize_allowed}, 0,    'anonymize is not allowed, customer is active';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_user',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    my $expected = [sort ($customer->get_client_loginid('VRTC'), $customer->get_client_loginid('CR'))];
    is $response->{status}, 'ok', 'call succeeded';
    is_deeply [sort @{$response->{clients}}], $expected, 'user client ids are as expected';

    $response = BOM::Service::user(
        context => $customer->get_user_service_context(),
        command => 'anonymize_status',
        user_id => $customer->get_user_id(),
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},           'ok', 'call succeeded';
    is $response->{anonymize_status}, 1,    'user is anonymized';

};

done_testing();
