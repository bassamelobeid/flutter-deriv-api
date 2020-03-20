use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;
use Time::Moment;
use Date::Utility;
use Brands;

use WebService::Async::Segment::Customer;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::User;
use BOM::User;
use BOM::Platform::Locale qw(get_state_by_id);

my %GENDER_MAPPING = (
    MR   => 'male',
    MRS  => 'female',
    MISS => 'female',
    MS   => 'female'
);

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => 'test1@bin.com',
});

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
$user->add_client($test_client_vr);

my (@identify_args, @track_args);
my $segment_response = Future->done(1);
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

my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    is_track_enabled => sub {
        my $self = shift;
        return ($self->name eq 'deriv');
    },
);

subtest 'General event validation - filtering by brand' => sub {
    undef @identify_args;
    undef @track_args;

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    like exception { BOM::Event::Services::Track::track_event(event => 'login')->get },
        qr/login tracking triggered without a loginid. Please inform backend team if it continues to occur./, 'Missing loginid exception';

    like exception { BOM::Event::Services::Track::track_event(event => 'login', loginid => 'CR1234')->get },
        qr/login tracking triggered with an invalid loginid CR1234. Please inform backend team if it continues to occur./,
        'Invalid loginid exception';

    $segment_response = Future->fail('dummy test failure');
    like exception { BOM::Event::Services::Track::track_event(event => 'login', loginid => $test_client->loginid)->get }, qr/dummy test failure/,
        'Correct exception raised';
    is @identify_args, 0, 'Segment identify is not invoked';
    ok @track_args, 'Segment track is invoked';
    my ($customer, %args) = @track_args;
    test_segment_customer($customer);
    my $expected_args = {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        },
        'event'      => 'login',
        'properties' => undef
    };
    is_deeply \%args, $expected_args;

    undef @track_args;
    $segment_response = Future->done(1);
    ok BOM::Event::Services::Track::track_event(
        event      => 'login',
        loginid    => $test_client->loginid,
        properties => {a => 1})->get, 'event emitted successfully';
    is @identify_args, 0, 'Segment identify is not invoked';
    ok @track_args, 'Segment tarck is invoked';
    ($customer, %args) = @track_args;
    $expected_args->{properties} = {a => 1};
    is_deeply \%args, $expected_args, 'track request args are correct';
    test_segment_customer($customer);

    undef @track_args;
    ok BOM::Event::Services::Track::track_event(
        event                => 'login',
        loginid              => $test_client->loginid,
        properties           => {a => 1},
        is_identify_required => 1
    )->get, 'event emitted successfully';
    ok @identify_args, 'Segment identify is invoked';
    ok @track_args,    'Segment tarck is invoked';
    ($customer, %args) = @track_args;
    is_deeply \%args, $expected_args, 'track request args are correct';
    test_segment_customer($customer);

    ($customer, %args) = @identify_args;
    is_deeply \%args,
        {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        }
        },
        'itentify request args are correct';
    test_segment_customer($customer);

    subtest 'tracking on a disabled brand' => sub {
        $req = BOM::Platform::Context::Request->new(
            brand_name => 'binary',
            language   => 'id'
        );
        request($req);

        undef @track_args;
        undef @identify_args;
        is BOM::Event::Services::Track::track_event(event => 'login')->get, undef, 'Response is empty when brand is not deriv';
        is @identify_args, 0, 'Segment identify is not invoked';
        is @track_args,    0, 'Segment track is not invoked';

        ok BOM::Event::Services::Track::track_event(
            event                => 'login',
            loginid              => $test_client->loginid,
            properties           => {a => 1},
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked (by setting brand to deriv in the args)';
        ok @track_args,    'Segment tarck is invoked (by setting brand to deriv in the args)';
        ($customer, %args) = @track_args;
        $expected_args->{context}->{app}->{name} = 'deriv';
        is_deeply \%args, $expected_args, 'track request args are correct with context brand switched to deriv';
        test_segment_customer($customer);

        ($customer, %args) = @identify_args;
        is_deeply \%args,
            {
            'context' => {
                'active' => 1,
                'app'    => {'name' => 'deriv'},
                'locale' => 'id'
            }
            },
            'itentify request args are correct with context brand switched to deriv';
        test_segment_customer($customer);

        $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'id'
        );
        request($req);
    };

    subtest 'mt5 ligin id list' => sub {
        $user->add_loginid('MT5900000');
        $user->add_loginid('MT5900001');
        undef @track_args;
        undef @identify_args;

        ok BOM::Event::Services::Track::track_event(
            event                => 'login',
            loginid              => $test_client->loginid,
            properties           => {a => 1},
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked';
        ok @track_args,    'Segment tarck is invoked';
        ($customer, %args) = @track_args;

        test_segment_customer($customer);

        is $customer->{traits}->{mt5_loginids}, 'MT5900000,MT5900001', 'MT5 account list is correct';
    };
};

sub test_segment_customer {
    my ($customer) = @_;

    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    my ($year, $month, $day) = split('-', $test_client->date_of_birth);

    my $expected_traits = {
        'email'      => $test_client->email,
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
        'created_at' => Date::Utility->new($test_client->date_joined)->datetime_iso8601,
        'address'    => {
            street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
            town        => $test_client->address_city,
            state       => BOM::Platform::Locale::get_state_by_id($test_client->state, $test_client->residence) // '',
            postal_code => $test_client->address_postcode,
            country     => Locale::Country::code2country($test_client->residence),
        },
        'currencies'   => '',
        'country'      => Locale::Country::code2country($test_client->residence),
        'mt5_loginids' => join(',', sort($user->get_mt5_loginids)),
    };

    is_deeply $customer->traits, $expected_traits, 'Customer traits are set correctly';

}

$mock_segment->unmock_all;
$mock_brands->unmock_all;

done_testing();
