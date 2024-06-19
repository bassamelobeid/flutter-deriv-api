use strict;
use warnings;

use Test::More;
use Test::MockModule;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use Future::AsyncAwait;
use HTTP::Response;
use Future::Exception;
use Test::MockObject;
use Array::Utils qw(:all);

###############################################################
my $expected_db_rows = [{
        'pa_url'     => 'http://www.masterexchanger.com/',
        'pa_loginid' => 'CR111111'
    },
    {
        'pa_loginid' => 'CR111112',
        'pa_url'     => 'https://truexgold.com/exchange_ngn_2_bin/'
    },
    {
        'pa_url'     => 'https://www.akuchanger.com/',
        'pa_loginid' => 'CR111113'
    },
    {
        'pa_loginid' => 'CR111114',
        'pa_url'     => 'https://www.cheapestdata.com/'
    },
    {
        'pa_loginid' => 'CR111119',
        'pa_url'     => 'cheapestdata.com/'
    },
    {
        'pa_loginid' => 'CR111110',
        'pa_url'     => 'www.cheapestdata.com/'
    }];

my $mock_payment_urls_check = Test::MockModule->new('BOM::User::Script::PaUrlCheck');

$mock_payment_urls_check->mock(
    get_pa_urls => sub {
        return $expected_db_rows;
    });

my $result       = BOM::User::Script::PaUrlCheck->new();
my $db           = $result->{brokers}{CR}{db};
my $urls_from_db = $result->get_pa_urls($db);
my @URLs         = $result->prepare_urls($db, $urls_from_db);

subtest 'check payment agent urls' => sub {
    my @expected_brokers  = qw(CR CRW AFF);
    my @generated_brokers = keys $result->{brokers}->%*;
    is(@generated_brokers, @expected_brokers, "");
    ok(!grep ($_->{pa_url} !~ /^http/, @URLs), "urls which are not starting with http filtered.");
};

my $mock_http = Test::MockModule->new('Net::Async::HTTP');
$mock_http->mock(
    GET => sub {
        #Here we are making response for a relative path successfull
        if ($_->{URI} eq 'https://www.cheapestdata.com/news') {
            my $response = Test::MockObject->new();
            $response->mock(code => sub { 200 });
        }
        if ($_->{pa_loginid} eq 'CR111111') {
            my $response = Test::MockObject->new();
            $response->mock(code => sub { 302 });
            return Future->done($response);
        }
        if ($_->{pa_loginid} eq 'CR111112') {
            my $response = Test::MockObject->new();
            $response->mock(code => sub { 404 });
            return Future->done($response);
        }
        #Here we are throwing an exception on the url and adding a relative path
        if ($_->{URI} eq 'https://www.cheapestdata.com/') {
            my $response = HTTP::Response->new();
            $response->header(Location => 'news');
            Future::Exception->throw('Unrecognised Location: news', 'http', $response);
        }

        my $response = Test::MockObject->new();
        $response->mock(code => sub { 200 });
        return Future->done($response);
    });

subtest 'check payment agent urls correct response' => async sub {
    my @respones                          = await $result->fmap_url_requests(@URLs);
    my $response_failed_302               = (grep { $_->{pa_loginid} =~ /^CR111111/ } @respones)[0];
    my $response_failed_404               = (grep { $_->{pa_loginid} =~ /^CR111112/ } @respones)[0];
    my $response_passed                   = (grep { $_->{pa_loginid} =~ /^CR111113/ } @respones)[0];
    my $response_passed_for_relative_path = (grep { $_->{pa_url} eq 'https://www.cheapestdata.com/' } @respones)[0];
    is($response_failed_302->{response_code},               302, "correct response received inaccessible path");
    is($response_failed_404->{response_code},               404, "correct response received inaccessible path");
    is($response_passed->{response_code},                   200, "correct response received accessible url");
    is($response_passed_for_relative_path->{response_code}, 200, "correct response received for relative path");
};

$mock_http->unmock_all;
$mock_payment_urls_check->unmock_all;

done_testing;
