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

subtest 'Check client changes are synced across clients' => sub {

    my $response = BOM::Service::user(
        context    => $context,
        command    => 'update_attributes_force',
        user_id    => $user->id,
        attributes => {
            first_name     => 'first_name_sync_test',
            last_name      => 'last_name_sync_test',
            address_line_1 => 'address_line_1_sync_test',
            address_line_2 => 'address_line_2_sync_test',
            phone          => 'phone_sync_test'
        });
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;
    is $response->{status}, 'ok', 'update tax_identification_number ok';
    is_deeply [sort @{$response->{affected}}], [sort qw(first_name last_name address_line_1 address_line_2 phone)],
        'affected array contains expected attributes';

    $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        user_id    => $user->id,
        attributes => [qw(first_name last_name address_line_1 address_line_2 phone)]);
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status},                       'ok',                       'update call succeeded';
    is $response->{attributes}->{first_name},     'first_name_sync_test',     'first_name was changed';
    is $response->{attributes}->{last_name},      'last_name_sync_test',      'last_name was changed';
    is $response->{attributes}->{address_line_1}, 'address_line_1_sync_test', 'address_line_1 was changed';
    is $response->{attributes}->{address_line_2}, 'address_line_2_sync_test', 'address_line_2 was changed';
    is $response->{attributes}->{phone},          'phone_sync_test',          'phone was changed';

    # Now get the other clients and check the same fields have been updated
    foreach my $loginid ($user->bom_real_loginids()) {
        my $client = BOM::User::Client->new({loginid => $loginid});
        is $client->first_name,     'first_name_sync_test',     $loginid . ' - first_name was changed';
        is $client->last_name,      'last_name_sync_test',      $loginid . ' - last_name was changed';
        is $client->address_line_1, 'address_line_1_sync_test', $loginid . ' - address_line_1 was changed';
        is $client->address_line_2, 'address_line_2_sync_test', $loginid . ' - address_line_2 was changed';
        is $client->phone,          'phone_sync_test',          $loginid . ' - phone was changed';
    }
};

done_testing();
