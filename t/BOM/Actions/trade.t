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
use BOM::Event::Actions::Trade;
use BOM::Event::Process;
use BOM::User;
use BOM::Platform::Locale qw(get_state_by_id);

my %GENDER_MAPPING = (
    MR   => 'male',
    MRS  => 'female',
    MISS => 'female',
    MS   => 'female'
);

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
    email       => 'test1@bin.com',
});
$test_client->set_default_account('EUR');

my $test_client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
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
    'is_track_enabled' => sub {
        my $self = shift;
        return ($self->name eq 'deriv');
    });

subtest 'buy event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    $segment_response = Future->done(1);
    my $call_args = {
        loginid                 => $test_client->loginid,
        'contract_id'           => '300120',
        'currency'              => 'AUD',
        'contract_category'     => 'staysinout',
        'contract_type'         => 'RANGE',
        'balance_after'         => '508.49',
        'source'                => 1,
        'buy_source'            => '10',
        'short_code'            => 'RANGE_FRXEURUSD_5_1310631887_1310688000_14360_14060',
        'supplied_high_barrier' => '0.014356',
        'supplied_low_barrier'  => '0.014057',
        'supplied_barrier'      => undef,
        'multiplier'            => undef,
        'app_markup_percentage' => 0,
        'buy_price'             => '3.46',
        'payout_price'          => '5.00',
        'is_expired'            => 0,
        'is_sold'               => 0,
        'purchase_time'         => '2020-01-02 09:40:50',
        'start_time'            => '2020-01-02 09:40:52',
        'sell_time'             => undef,
        'expiry_time'           => '2020-01-02 10:00:00',
        'settlement_time'       => '2020-01-02 10:00:00',
        'underlying_symbol'     => 'frxUSDJPY',
        'transaction_id'        => 12,
    };
    my $handler = BOM::Event::Process::get_action_mappings()->{buy};
    my $result  = $handler->($call_args)->get;
    is $result, 1, 'Success track result';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my $expected_props = {
        %$call_args,
        value           => $call_args->{buy_price},
        revenue         => -$call_args->{buy_price},
        purchase_time   => '2020-01-02T09:40:50Z',
        start_time      => '2020-01-02T09:40:52Z',
        expiry_time     => '2020-01-02T10:00:00Z',
        settlement_time => '2020-01-02T10:00:00Z',

    };
    $expected_props->{app_id} = delete $expected_props->{source};

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'buy',
        properties => $expected_props,
        },
        'track context and properties are correct.';
    undef @track_args;

    $call_args->{loginid} = $test_client_vr->loginid;
    $result = $handler->($call_args)->get;
    is $result, undef, 'Empty track result (no event emitted) for trading with virtual account';
    is scalar @identify_args, 0, 'No identify event is triggered for virtual account';
    is scalar @track_args,    0, 'No track event is triggered when for virtual account';
    $call_args->{loginid} = $test_client->loginid;

    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $handler->($call_args)->get;
    is $result, undef, 'Empty track result (no event emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered when brand is binary';
    is scalar @track_args,    0, 'No track event is triggered when brand is binary';
};

subtest 'sell event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);
    undef @identify_args;
    undef @track_args;

    $segment_response = Future->done(1);
    my $call_args = {
        loginid                 => $test_client->loginid,
        currency                => 'AUD',
        'contract_id'           => '300120',
        'contract_category'     => 'staysinout',
        'contract_type'         => 'RANGE',
        'balance_after'         => '508.49',
        'source'                => 1,
        'buy_source'            => 1,
        'copy_trading'          => 1,
        'auto_expired'          => 0,
        'short_code'            => 'RANGE_FRXEURUSD_5_1310631887_1310688000_14360_14060',
        'supplied_high_barrier' => '0.014356',
        'supplied_low_barrier'  => '0.014057',
        'supplied_barrier'      => undef,
        'multiplier'            => undef,
        'app_markup_percentage' => 0,
        'buy_price'             => '3.46',
        'payout_price'          => '5.00',
        'sell_price'            => '4.5',
        'is_expired'            => 1,
        'is_sold'               => 1,
        'purchase_time'         => '2020-01-02 09:40:50',
        'start_time'            => '2020-01-02 09:40:52',
        'sell_time'             => '2020-01-02 09:40:58',
        'expiry_time'           => '2020-01-02 10:00:00',
        'settlement_time'       => '2020-01-02 10:00:00',
        'underlying_symbol'     => 'frxUSDJPY',
    };
    my $expected_props = {
        %$call_args,
        loginid         => $test_client->loginid,
        value           => $call_args->{sell_price},
        revenue         => $call_args->{sell_price},
        purchase_time   => '2020-01-02T09:40:50Z',
        start_time      => '2020-01-02T09:40:52Z',
        sell_time       => '2020-01-02T09:40:58Z',
        expiry_time     => '2020-01-02T10:00:00Z',
        settlement_time => '2020-01-02T10:00:00Z',
    };
    $expected_props->{app_id}     = delete $expected_props->{source};
    $expected_props->{buy_app_id} = delete $expected_props->{buy_source};

    my $handler = BOM::Event::Process::get_action_mappings()->{sell};
    my $result  = $handler->($call_args)->get;
    is $result, 1, 'Expected return value';

    is scalar @identify_args, 0, 'No identify event is triggered';

    my ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'sell',
        properties => $expected_props,
        },
        'track context and properties are correct.';
    undef @track_args;

    #brand switches according to buy_source, if trade is auto-expired
    $call_args->{auto_expired} = $expected_props->{auto_expired} = 1;
    $result = $handler->($call_args)->get;
    is $result, undef, 'Empty return value (no event emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered (buy source is binary)';
    is scalar @track_args,    0, 'No track event is triggered (app id swithched for auto-sold trades)';

    $call_args->{loginid} = $test_client_vr->loginid;
    $result = $handler->($call_args)->get;
    is $result, undef, 'Empty track result (no event emitted) for trading with virtual account';
    is scalar @identify_args, 0, 'No identify event is triggered for virtual account';
    is scalar @track_args,    0, 'No track event is triggered when for virtual account';
    $call_args->{loginid} = $test_client->loginid;

    # trigger by auto-switch
    $req = BOM::Platform::Context::Request->new(
        brand_name => 'binary',
        language   => 'id'
    );
    request($req);
    $result = $handler->($call_args)->get;
    is $result, undef, 'Empty return value (no event emitted)';
    is scalar @identify_args, 0, 'No identify event is triggered';
    is scalar @track_args,    0, 'No track event is triggered (brand is binary)';

    my $deriv_apps = Brands->new(name => 'deriv')->whitelist_apps();
    $call_args->{buy_source} = $expected_props->{buy_app_id} = (keys %$deriv_apps)[0];
    $result = $handler->($call_args)->get;
    is $result, 1, 'Success track result';
    is scalar @identify_args, 0, 'No identify event is triggered';
    cmp_ok scalar @track_args, '>', 1, 'Track event is triggered';

    ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'sell',
        properties => $expected_props,
        },
        'track context and properties are correct.';

    undef @track_args;
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at) = @_;
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    $created_at //= Date::Utility->today;
    my ($year, $month, $day) = split('-', $test_client->date_of_birth);

    is_deeply $customer->traits,
        {
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
        'created_at' => Date::Utility->new($created_at)->datetime_iso8601,
        'gender'     => $GENDER_MAPPING{uc($test_client->salutation)},
        'address'    => {
            street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
            town        => $test_client->address_city,
            state       => BOM::Platform::Locale::get_state_by_id($test_client->state, $test_client->residence) // '',
            postal_code => $test_client->address_postcode,
            country     => Locale::Country::code2country($test_client->residence),
        },
        'currencies' => $currencies,
        'country'    => Locale::Country::code2country($test_client->residence),
        },
        'Customer traits are set correctly';
}

$mock_brands->unmock_all;
$mock_segment->unmock_all;

done_testing();
