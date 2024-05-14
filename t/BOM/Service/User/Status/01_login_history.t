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
my $context = UserServiceTestHelper::create_context($user);

my $dump_response = 0;

isa_ok $user, 'BOM::User', 'Test user available';

subtest 'get login history missing params show_backoffice' => sub {
    my $response = BOM::Service::user(
        context => $context,
        command => 'get_login_history',
        user_id => $user->id,
        limit   => 10,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'message returned';
    like $response->{message}, qr/.+show_backoffice/, 'Missing show_backoffice parameter';
};

subtest 'get login history missing params limit' => sub {
    my $test_name = 'get login history missing params limit';
    my $response  = BOM::Service::user(
        context         => $context,
        command         => 'get_login_history',
        user_id         => $user->id,
        show_backoffice => 0,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'error', 'call failed';
    ok $response->{message}, 'message returned';
    like $response->{message}, qr/.+limit/, 'Missing limit parameter';
};

subtest 'get login history all' => sub {
    my $test_name = 'get login history all';
    my $response  = BOM::Service::user(
        context         => $context,
        command         => 'get_login_history',
        user_id         => $user->id,
        limit           => 100,
        show_backoffice => 1,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message},      'no message returned';
    ok $response->{login_history}, 'login history returned';
    is scalar(@{$response->{login_history}}), 5, 'all 5 returned';
};

subtest 'get login history non backoffice' => sub {
    my $test_name = 'get login history non backoffice';
    my $response  = BOM::Service::user(
        context         => $context,
        command         => 'get_login_history',
        user_id         => $user->id,
        limit           => 10,
        show_backoffice => 0,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message},      'no message returned';
    ok $response->{login_history}, 'login history returned';
    is scalar(@{$response->{login_history}}), 2, 'limit 2 returned';
};

subtest 'get login history limit' => sub {
    my $test_name = 'get login history limit';
    my $response  = BOM::Service::user(
        context         => $context,
        command         => 'get_login_history',
        user_id         => $user->id,
        limit           => 1,
        show_backoffice => 0,
    );
    print JSON::MaybeXS->new->pretty->encode($response) . "\n" if $dump_response;

    is $response->{status}, 'ok', 'call succeeded';
    ok !$response->{message},      'no message returned';
    ok $response->{login_history}, 'login history returned';
    is scalar(@{$response->{login_history}}), 1, 'limit 1 returned';
};

done_testing();
