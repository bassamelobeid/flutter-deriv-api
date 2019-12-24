use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Exception;
use Test::MockModule;

use WebService::Async::Segment::Customer;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::Track;
use BOM::User;
use Time::Moment;
use Date::Utility;

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});

my $email = $test_client->email;
my $user  = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);

$user->add_client($test_client);

my (@identify_args, @track_args);
my $segment_response = Future->fail(1);
my $mock_segment     = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return $segment_response;
    },
    'track' => sub {
        @track_args = @_;
        return $segment_response;
    });

subtest 'General event validation' => sub {
    undef @identify_args;
    undef @track_args;

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);

    is BOM::Event::Actions::Track::login()->get, undef, 'Request is skipped if barnd is not deriv';
    is @identify_args, 0, 'Segment identify is not invoked';
    is @track_args,    0, 'Segment track is not invoked';

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    throws_ok { BOM::Event::Actions::Track::login()->get; }
    qr/Login tracking triggered without a loginid. Please inform back end team if this continues to occur./, 'Missing loginid exception';
    my $args = {loginid => 'CR1234'};
    throws_ok { BOM::Event::Actions::Track::login($args)->get }
    qr/Login tracking triggered with an invalid loginid. Please inform back end team if this continues to occur./, 'Invalid loginid exception';

    $args->{loginid} = $test_client->loginid;

    $segment_response = Future->fail('dummy test failure');
    throws_ok { BOM::Event::Actions::Track::login($args)->get; } qr/dummy test failure/, 'Dummy test failure raised by triggering login';
};

subtest 'login event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    my $virtual_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => $email
    });
    $user->add_client($virtual_client);
    $segment_response = Future->done(1);
    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            browser  => 'chrome',
            device   => 'Mac OS X',
            ip       => '127.0.0.1',
            location => 'Germany'
        }};
    my $result = BOM::Event::Actions::Track::login($args)->get;
    is $result, 1, 'Success track result';
    my ($customer, %args) = @identify_args;
    test_segment_customer($customer, $test_client, '', $virtual_client->date_joined);

    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        }
        },
        'identify context is properly set';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client, '', $virtual_client->date_joined);
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'login',
        properties => {
            browser  => 'chrome',
            device   => 'Mac OS X',
            ip       => '127.0.0.1',
            location => 'Germany'
        }
        },
        'identify context and properties is properly set.';

    $test_client->set_default_account('EUR');

    ok BOM::Event::Actions::Track::login($args)->get, 'successful login track after setting currency';
    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client, 'EUR', $virtual_client->date_joined);

    undef @identify_args;
    undef @track_args;
    $args->{loginid} = $virtual_client->loginid;
    ok BOM::Event::Actions::Track::login($args)->get, 'login triggered with virtual loginid';

    ($customer, %args) = @identify_args;
    test_segment_customer($customer, $virtual_client, 'EUR', $virtual_client->date_joined);

    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        }
        },
        'identify context is properly set';
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at) = @_;
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    my ($year, $month, $day) = split('-', $test_client->date_of_birth);
    is_deeply $customer->traits,
        {
        'email'      => $email,
        'first_name' => $test_client->first_name,
        'last_name'  => $test_client->last_name,
        'birthday'   => $test_client->date_of_birth,
        'age'        => (
            Time::Moment->new(
                year  => $year,
                month => $month,
                day   => $day
            )->delta_years(Time::Moment->now_utc)
        ),
        'phone'      => $test_client->phone,
        'created_at' => Date::Utility->new($created_at)->datetime_iso8601,
        'address'    => {
            street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
            town        => $test_client->address_city,
            state       => $test_client->address_state,
            postal_code => $test_client->address_postcode,
            country     => Locale::Country::code2country($test_client->residence),
        },
        'currencies' => $currencies,
        'country'    => Locale::Country::code2country($test_client->residence),
        },
        'Customer traits are set correctly';
}

done_testing();
