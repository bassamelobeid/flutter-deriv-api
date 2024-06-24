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

my $user    = UserServiceTestHelper::create_user('frieren@strahl.com');
my $context = UserServiceTestHelper::get_user_service_context();

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'get all the things' => sub {
    my $response = BOM::Service::user(
        context => $context,
        command => 'get_all_attributes',
        user_id => $user->id
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message}, 'no message returned';

    # Won't check them all just a couple to be sure from user/client
    is $response->{attributes}{first_name},     'Frieren',            'first_name ok';
    is $response->{attributes}{last_name},      'Elf',                'last_name ok';
    is $response->{attributes}{email},          'frieren@strahl.com', 'email ok';
    is $response->{attributes}{email_verified}, 1,                    'email_verified ok';

    # Make sure all keys are present in the response object
    my $attr_ref  = BOM::Service::User::Attributes::get_all_attributes();
    my @attr_list = keys %$attr_ref;
    is scalar(keys %{$response->{attributes}}), scalar @attr_list, 'all attributes returned';
};

subtest 'get full_name test' => sub {
    my $response = BOM::Service::user(
        context    => $context,
        command    => 'get_attributes',
        attributes => [qw(full_name salutation first_name last_name)],
        user_id    => $user->id
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';

    # Won't check them all just a couple to be sure from user/client
    is $response->{attributes}{first_name}, 'Frieren',          'first_name ok';
    is $response->{attributes}{last_name},  'Elf',              'last_name ok';
    is $response->{attributes}{salutation}, 'Miss',             'salutation ok';
    is $response->{attributes}{full_name},  'Miss Frieren Elf', 'full_name ok';
};

done_testing();
