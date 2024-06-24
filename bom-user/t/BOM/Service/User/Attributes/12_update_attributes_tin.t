use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::Exception;
use Test::MockModule;
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

subtest 'Check tin is undef from tax_identification_number update' => sub {

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(tax_identification_number tin_approved_time)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                                  'ok',                  'update call succeeded';
    is $response->{attributes}->{tax_identification_number}, '9999999999',          'tax_identification_number was changed';
    is $response->{attributes}->{tin_approved_time},         '1984-01-01T00:00:00', 'tin_approved_time is empty';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes',
        user_id    => $user->id,
        attributes => {tax_identification_number => '1234567890'});
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update tax_identification_number ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(tax_identification_number tin_approved_time)], 'affected array contains expected attributes';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(tax_identification_number tin_approved_time)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status},                                  'ok',         'update call succeeded';
    is $response->{attributes}->{tax_identification_number}, '1234567890', 'tax_identification_number was changed';
    is $response->{attributes}->{tin_approved_time},         undef,        'tin_approved_time is empty';
};

done_testing();
