use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;

use JSON::MaybeUTF8 qw( encode_json_utf8 );

use BOM::Database::ClientDB;
use BOM::Platform::CloseIO;
use BOM::Test;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

my $user = BOM::User->create(
    email          => 'test@binary.com',
    password       => BOM::User::Password::hashpw('abcd'),
    email_verified => 1,
);

my @requests;
my $get_response;
my $delete_response;

my $mock_http = Test::MockModule->new('HTTP::Tiny');
$mock_http->mock(
    'request',
    sub {
        my (undef, $method, $url) = @_;

        push @requests,
            {
            method => $method,
            url    => $url
            };

        # Return different responses based on the request type
        if ($method eq 'GET') {
            return $get_response;
        } elsif ($method eq 'DELETE') {
            return $delete_response;
        }
    });

subtest 'initialization' => sub {
    throws_ok {
        BOM::Platform::CloseIO->new
    }
    qr/Missing required arguments: user/;

    lives_ok {
        BOM::Platform::CloseIO->new(user => $user);
    }
    'Instance created successfully';
};

subtest 'search_lead' => sub {
    @requests = ();

    my $close = BOM::Platform::CloseIO->new(user => $user);

    throws_ok {
        $close->search_lead();
    }
    qr/Please define at least one filter./;

    $get_response = {success => 0};
    my $response = $close->search_lead('keyword1');

    is scalar @requests, 1,             'request performed';
    is $response,        $get_response, 'error happened';

    @requests = ();

    $get_response = {
        success => 1,
        content => {data => 'ok'}};
    $response = $close->search_lead('keyword1', 'sample2');

    is scalar @requests,       1,     'request performed';
    is $requests[0]->{method}, 'GET', 'method is correct';
    like $requests[0]->{url}, qr/lead\?query=keyword1%2Csample2/, 'the parameters are correct';
    is $response->{data}, 'ok', 'response correct';
};

subtest 'delete_lead' => sub {
    @requests = ();

    my $close = BOM::Platform::CloseIO->new(user => $user);

    throws_ok {
        $close->delete_lead();
    }
    qr/Missing lead_id/;

    $delete_response = {success => 0};
    my $response = $close->delete_lead('id1');

    is scalar @requests, 1,                'request performed';
    is $response,        $delete_response, 'error happened';

    @requests = ();

    $delete_response = {
        success => 1,
        content => {}};
    $response = $close->delete_lead('id4');

    is scalar @requests,       1,        'request performed';
    is $requests[0]->{method}, 'DELETE', 'method is correct';
    like $requests[0]->{url}, qr/lead\/id4/, 'the parameters are correct';
    ok defined $response, 'response correct';
};

subtest 'anonymize user' => sub {
    @requests = ();

    my $close = BOM::Platform::CloseIO->new(user => $user);

    $get_response = {success => 0};
    my $result = $close->anonymize_user();

    is scalar @requests, 1, '1 request performed';
    ok !$result, 'error happened, anonymization not done';

    @requests = ();

    $get_response = {
        success => 1,
        content => encode_json_utf8 {
            data          => [{id => '1'}, {id => '2'}],
            total_results => 2
        }};
    $delete_response = {success => 1};
    $result          = $close->anonymize_user();

    is scalar @requests, 3, '1 request performed';
    ok $result, 'user anonymized.';

    @requests = ();

    $get_response = {
        success => 1,
        content => encode_json_utf8 {
            data          => [{id => 'id9'}],
            total_results => 1
        }};
    $delete_response = {success => 1};
    $result          = $close->anonymize_user();

    is scalar @requests,       2,     '2 request performed';
    is $requests[0]->{method}, 'GET', 'method of first call is correct';
    like $requests[0]->{url}, qr/lead\?query=test%40binary.com/, 'queries of first call is correct';

    is $requests[1]->{method}, 'DELETE', 'method of second call is correct';
    like $requests[1]->{url}, qr/lead\/id9/, 'the parameters of second call are correct';

    ok $result, 'user anonymized.';

    @requests = ();

    $get_response = {
        success => 1,
        content => encode_json_utf8 {
            data          => [],
            total_results => 0
        }};
    $result = $close->anonymize_user();

    is scalar @requests,       1,     '1 request performed';
    is $requests[0]->{method}, 'GET', 'method of first call is correct';
    like $requests[0]->{url}, qr/lead\?query=test%40binary.com/, 'queries of first call is correct';

    @requests = ();

    $get_response = {
        success => 1,
        content => encode_json_utf8 {
            data          => [{id => 'id11'}],
            total_results => 1
        }};
    $delete_response = {
        success => 0,
        status  => 404,
        content => 'not found'
    };

    $result = $close->anonymize_user();

    is scalar @requests,       2,     '2 request performed';
    is $requests[0]->{method}, 'GET', 'method of first call is correct';
    like $requests[0]->{url}, qr/lead\?query=test%40binary.com/, 'queries of first call is correct';
    is $requests[1]->{method}, 'DELETE', 'method of second call is correct';
    like $requests[1]->{url}, qr/lead\/id11/, 'the parameters of second call are correct';

    ok !$result, 'user not anonymized';
};

done_testing();
