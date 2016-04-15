use JSON qw( from_json to_json );
use CGI qw( cookie );
use URL::Encode qw(url_encode);
use JSON qw(decode_json);

use Test::More $ENV{SKIP_MYAFFILIATES} ? (skip_all => 'SKIP_MYAFFILIATES set') : ('no_plan');
use Test::NoWarnings;
use Test::Exception;
use Test::Warn;
use Test::MockModule;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use Data::Hash::DotNotation;
use BOM::Platform::Context;
use BOM::Platform::Client;
use BOM::Platform::MyAffiliates::TrackingHandler;

use BOM::Utility::Log4perl;

subtest 'Basic Instantiation.' => sub {
    my $handler;
    lives_ok { $handler = BOM::Platform::MyAffiliates::TrackingHandler->new } 'Creating an instance doesn\'t cause us to die.';
    ok !$handler->myaffiliates_token, 'No token';
    ok !$handler->tracking_cookie,    'Nothing to expose, nothing to delete';
};

subtest 'Invalid cookie' => sub {
    my $request = BOM::Platform::Context::Request->new(cookies => {'affiliate_tracking' => 'some garbled\' data'});
    BOM::Platform::Context::request($request);
    my $handler;
    warnings_like {
        $handler = BOM::Platform::MyAffiliates::TrackingHandler->new();
        $handler->myaffiliates_token;
    }
    [qr/Failed to parse tracking cookie/], 'warns when cannot load data from cookie';
    ok !$handler->myaffiliates_token, "Not able to parse so no token";
    #No need to keep invalid cookie for a later date and subsequent warnings.
    exposure_cookie_is_deleted($handler->tracking_cookie);
};

subtest 'Client not logged in' => sub {
    my $existing_cookie_value = to_json({t => 'pq4yxSo2Q5MxbH2GzcxdS2nD7zGQDrlQ'});

    my $request = BOM::Platform::Context::Request->new(cookies => {'affiliate_tracking' => $existing_cookie_value});
    BOM::Platform::Context::request($request);

    my $handler = BOM::Platform::MyAffiliates::TrackingHandler->new();
    is $handler->myaffiliates_token, 'pq4yxSo2Q5MxbH2GzcxdS2nD7zGQDrlQ', "Parsed the cookie";
    ok !$handler->tracking_cookie, 'Not yet exposed so not deleted';
};

subtest 'Client logged in' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    subtest 'Legacy Affiliate Tracker' => sub {
        my $number_of_exposures = $client->client_affiliate_exposure_count;
        # assuming CR1234 was never an affiliate in the BOM system.
        my $existing_cookie_value = to_json({a => 'CR1234'});

        my $request = BOM::Platform::Context::Request->new(
            cookies => {'affiliate_tracking' => $existing_cookie_value},
            loginid => $client->loginid
        );
        BOM::Platform::Context::request($request);
        my $handler = BOM::Platform::MyAffiliates::TrackingHandler->new();

        my $new_number_of_exposures = $client->client_affiliate_exposure_count;
        is scalar $new_number_of_exposures, $number_of_exposures, 'No new exposure';
        ok !$handler->tracking_cookie, 'Not yet exposed so not deleted';
    };
};

sub exposure_cookie_is_deleted {
    my $cookie = shift;

    is(UNIVERSAL::isa($cookie, 'CGI::Cookie'), 1, 'There IS a cookie to be sent out...');
    is($cookie->value, '', 'Full data in cookie, client logged in => exposure was flushed to DB, cookie should be emptied.',);

    # to test that expiry will delete cookie, wanted to use mocktime, but it just wasn't able to
    # manipulate the time that the CGI module uses. So instead, roughly test the expiry by
    # assuming it's on the same day and hour as the current time:
    my $now = Date::Utility->new;

    my $ddmmmyyyy = $now->date_ddmmmyyyy;
    #Precede 0 to the signle digit dates. Why does this date claim its in ddmmmmyyyy format while its in dmmmyyyy format?
    $ddmmmyyyy =~ s/^(\d)\-/0$1-/;

    my $like = $now->day_as_string . ', ' . $ddmmmyyyy . ' ' . $now->hour;
    like($cookie->expires, qr/$like/, '..and cookie expiry is quite close to the current time (suggesting that it is as it should be.)');
}

