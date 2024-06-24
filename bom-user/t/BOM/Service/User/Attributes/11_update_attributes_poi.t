use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use UUID::Tiny;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/../../../../lib";

use BOM::Service;
use BOM::User;
use BOM::User::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use UserServiceTestHelper;

my $email   = 'frieren@strahl.com';
my $user    = UserServiceTestHelper::create_user($email);
my $context = UserServiceTestHelper::get_user_service_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'Check poi is triggered' => sub {
    my $finalise_poi_check   = 0;
    my $finalise_onfido_sync = 0;
    # Need to redefine the handler map as the mock as its already setup
    $BOM::Service::User::Attributes::Update::finalise_handler_map{poi_check}   = \&{$finalise_poi_check   = 1;};
    $BOM::Service::User::Attributes::Update::finalise_handler_map{onfido_sync} = \&{$finalise_onfido_sync = 1;};

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {first_name => 'test'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update first_name ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(first_name)], 'affected array contains expected attributes';
    is $finalise_poi_check,   1, 'finalise_poi_check finalise was called';
    is $finalise_onfido_sync, 1, 'finalise_onfido_sync finalise was called';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                   'ok',   'update call succeeded';
    is $response->{attributes}->{first_name}, 'test', 'first name was changed';

    # Restore handlers
    $BOM::Service::User::Attributes::Update::finalise_handler_map{poi_check} = \&BOM::Service::User::Attributes::Update::FinaliseHandlers::poi_check;
    $BOM::Service::User::Attributes::Update::finalise_handler_map{onfido_sync} =
        \&BOM::Service::User::Attributes::Update::FinaliseHandlers::onfido_sync;
};

done_testing();
