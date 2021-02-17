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

my @enabled_brands = ('deriv');
my $mock_brands    = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });
$mock_brands->mock(
    'is_app_whitelisted' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $mock_mt5_groups = Test::MockModule->new('BOM::User');
$mock_mt5_groups->mock(
    mt5_logins_with_group => sub {
        return {};
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

    like exception { BOM::Event::Services::Track::track_event(event => 'UNKNOWN', loginid => $test_client->loginid)->get },
        qr/Unknown event <UNKNOWN> tracking request was triggered by the client CR10000/,
        'Unknown event exception';

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
        'properties' => {
            'brand' => 'deriv',
        }};
    is_deeply \%args, $expected_args;

    undef @track_args;
    $segment_response = Future->done(1);
    ok BOM::Event::Services::Track::track_event(
        event      => 'login',
        loginid    => $test_client->loginid,
        properties => {a => 1},
    )->get, 'event emitted successfully';
    is @identify_args, 0, 'Segment identify is not invoked';
    ok @track_args, 'Segment track is invoked';
    ($customer, %args) = @track_args;
    $expected_args->{properties} = {'brand' => 'deriv'};
    is_deeply \%args, $expected_args, 'track request args are correct - invalid property filtered out';
    test_segment_customer($customer);

    undef @track_args;
    ok BOM::Event::Services::Track::track_event(
        event                => 'login',
        loginid              => $test_client->loginid,
        properties           => {browser => 'fire-chrome'},
        is_identify_required => 1
    )->get, 'event emitted successfully';
    ok @identify_args, 'Segment identify is invoked';
    ok @track_args,    'Segment track is invoked';
    ($customer, %args) = @track_args;
    $expected_args->{properties}->{browser} = 'fire-chrome';
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
        'identify request args are correct';
    test_segment_customer($customer, \%args);

    subtest 'tracking on a disabled brand' => sub {
        $req = BOM::Platform::Context::Request->new(
            brand_name => 'champion',
            language   => 'id'
        );
        request($req);

        undef @track_args;
        undef @identify_args;
        is BOM::Event::Services::Track::track_event(event => 'login')->get, undef, 'Response is empty when brand is not \'deriv\' or \'binary\'';
        is @identify_args, 0, 'Segment identify is not invoked';
        is @track_args,    0, 'Segment track is not invoked';

        foreach (@enabled_brands) {
            my $brand = $_;

            $req = BOM::Platform::Context::Request->new(
                brand_name => $brand,
                language   => 'id'
            );
            request($req);

            undef @track_args;
            undef @identify_args;
            ok BOM::Event::Services::Track::track_event(
                event                => 'login',
                loginid              => $test_client->loginid,
                properties           => {browser => 'fire-chrome'},
                is_identify_required => 1,
                brand                => Brands->new(name => $brand))->get, 'event emitted successfully';
            ok @identify_args, "Segment identify is invoked (by setting brand to '$brand' in the args)";
            ok @track_args,    "Segment track is invoked (by setting brand to '$brand' in the args)";
            ($customer, %args) = @track_args;
            $expected_args->{context}->{app}->{name} = $brand;
            $expected_args->{properties}->{brand} = $brand;
            is_deeply \%args, $expected_args, "track request args are correct with context brand switched to '$brand'";
            test_segment_customer($customer);

            ($customer, %args) = @identify_args;
            is_deeply \%args,
                {
                'context' => {
                    'active' => 1,
                    'app'    => {'name' => $brand},
                    'locale' => 'id'
                }
                },
                "identify request args are correct with context brand switched to '$brand'";
            test_segment_customer($customer, \%args);
        }
    };

    subtest 'mt5 ligin id list' => sub {
        $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'id'
        );
        request($req);

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
        ok @track_args,    'Segment track is invoked';
        ($customer, %args) = @track_args;

        test_segment_customer($customer, \%args);

        is $customer->{traits}->{mt5_loginids}, 'MT5900000,MT5900001', 'MT5 account list is correct';
    };

    subtest 'Set unsubscribed to false on `profile_change` event' => sub {
        undef @track_args;
        undef @identify_args;

        $user->update_email_fields(email_consent => 1);
        ok BOM::Event::Services::Track::track_event(
            event                => 'profile_change',
            loginid              => $test_client->loginid,
            properties           => {email_consent => 1},
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked';
        ok @track_args,    'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "profile_change",
                properties => {
                    email_consent => 1,
                    brand         => 'deriv'
                },
            },
            'identify context is properly set for profile_change'
        );

        is $customer->{traits}->{unsubscribed}, 'false', '\'unsubscribed\' is set to false';
    };

    subtest 'Set unsubscribed to true on `account_closure` event' => sub {
        undef @track_args;
        undef @identify_args;

        $user->update_email_fields(email_consent => 0);
        ok BOM::Event::Services::Track::track_event(
            event      => 'account_closure',
            loginid    => $test_client->loginid,
            properties => {
                closing_reason => 'Test',
                email_consent  => 0,
            },
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked';
        ok @track_args,    'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "account_closure",
                properties => {
                    brand          => 'deriv',
                    closing_reason => 'Test',
                    email_consent  => 0,
                },
            },
            'identify context is properly set for account_closure'
        );

        is $customer->{traits}->{unsubscribed}, 'true', '\'unsubscribed\' is set to true';
    };

    subtest 'Set unsubscribed to true on `self_exclude` event' => sub {
        undef @track_args;
        undef @identify_args;

        my $exclude_until = Date::Utility->new()->plus_time_interval('365d')->date;
        $test_client->set_exclusion->exclude_until($exclude_until);
        $test_client->save;
        ok BOM::Event::Services::Track::track_event(
            event      => 'self_exclude',
            loginid    => $test_client->loginid,
            properties => {
                unsubscribed => 1,
            },
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked';
        ok @track_args,    'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "self_exclude",
                properties => {
                    brand        => 'deriv',
                    unsubscribed => 1,
                },
            },
            'identify context is properly set for self_exclude event'
        );

        test_segment_customer($customer, \%args);

        undef @track_args;
        undef @identify_args;

        $user->update_email_fields(email_consent => 1);
        ok BOM::Event::Services::Track::track_event(
            event                => 'profile_change',
            loginid              => $test_client->loginid,
            properties           => {email_consent => 1},
            is_identify_required => 1,
            brand                => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        ok @identify_args, 'Segment identify is invoked';
        ok @track_args,    'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "profile_change",
                properties => {
                    brand         => 'deriv',
                    email_consent => 1,
                },
            },
            'identify context is properly set for profile_change'
        );

        test_segment_customer($customer, \%args);
        # We expect `unsubscribed` flag to remain true as long as client is self excluded
        # when other events are triggered
        is $customer->{traits}->{unsubscribed}, 'true', '\'unsubscribed\' remains as true';
    };

    subtest 'payment_deposit' => sub {
        undef @track_args;
        undef @identify_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_deposit',
            loginid    => $test_client->loginid,
            properties => {
                payment_processor => 'QIWI',
                transaction_id    => 123,
                is_first_deposit  => 0,
                trace_id          => 11,
                amount            => '10',
                payment_fee       => '0',
                currency          => 'USD',
                payment_method    => 'VISA',
            },
            brand => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        is @identify_args, 0, 'Segment identify is not invoked';
        ok @track_args, 'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "payment_deposit",
                properties => {
                    brand             => 'deriv',
                    payment_processor => 'QIWI',
                    transaction_id    => 123,
                    is_first_deposit  => 0,
                    trace_id          => 11,
                    amount            => '10',
                    payment_fee       => '0',
                    currency          => 'USD',
                    payment_method    => 'VISA',
                },
            },
            'track args is properly set for doughflow payment_deposit'
        );

        undef @track_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_deposit',
            loginid    => $test_client->loginid,
            properties => {
                amount   => '10',
                currency => 'USD',
                remark   => 'test123',
            },
            brand => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        is @identify_args, 0, 'Segment identify is not invoked';
        ok @track_args, 'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "payment_deposit",
                properties => {
                    brand    => 'deriv',
                    amount   => '10',
                    currency => 'USD',
                    remark   => 'test123',
                },
            },
            'track args is properly set for cryptocashier payment_deposit'
        );
    };

    subtest 'payment_withdrawal' => sub {
        undef @track_args;
        undef @identify_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_withdrawal',
            loginid    => $test_client->loginid,
            properties => {
                transaction_id => 124,
                trace_id       => 12,
                amount         => '-10',
                payment_fee    => '0',
                currency       => 'USD',
                payment_method => 'VISA',
            },
            brand => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        is @identify_args, 0, 'Segment identify is not invoked';
        ok @track_args, 'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "payment_withdrawal",
                properties => {
                    brand          => 'deriv',
                    transaction_id => 124,
                    trace_id       => 12,
                    amount         => '-10',
                    payment_fee    => '0',
                    currency       => 'USD',
                    payment_method => 'VISA',
                },
            },
            'track args is properly set for doughflow payment_withdrawal'
        );

        undef @track_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_withdrawal',
            loginid    => $test_client->loginid,
            properties => {
                amount   => '-10',
                currency => 'USD',
            },
            brand => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        is @identify_args, 0, 'Segment identify is not invoked';
        ok @track_args, 'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "payment_withdrawal",
                properties => {
                    brand    => 'deriv',
                    amount   => '-10',
                    currency => 'USD',
                },
            },
            'track args is properly set for cryptocashier payment_withdrawal'
        );
    };

    subtest 'payment_withdrawal_reversal' => sub {
        undef @track_args;
        undef @identify_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_withdrawal_reversal',
            loginid    => $test_client->loginid,
            properties => {
                transaction_id => 124,
                trace_id       => 12,
                amount         => '-10',
                payment_fee    => '-10',
                currency       => 'USD',
                payment_method => 'VISA',
            },
            brand => Brands->new(name => 'deriv'))->get, 'event emitted successfully';
        is @identify_args, 0, 'Segment identify is not invoked';
        ok @track_args, 'Segment track is invoked';
        ($customer, %args) = @track_args;

        is_deeply(
            \%args,
            {
                context => {
                    active => 1,
                    app    => {name => "deriv"},
                    locale => "id"
                },
                event      => "payment_withdrawal_reversal",
                properties => {
                    brand          => 'deriv',
                    transaction_id => 124,
                    trace_id       => 12,
                    amount         => '-10',
                    payment_fee    => '-10',
                    currency       => 'USD',
                    payment_method => 'VISA',
                },
            },
            'track args is properly set for payment_withdrawal_reversal'
        );
    };
};

sub test_segment_customer {
    my ($customer, $args) = @_;

    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
    my ($year, $month, $day) = split('-', $test_client->date_of_birth);

    my $has_exclude_until = $test_client->get_self_exclusion  ? $test_client->get_self_exclusion->exclude_until : undef;
    my $unsubscribed      = $test_client->user->email_consent ? 'false'                                         : 'true';
    if (defined($args->{properties}->{unsubscribed} || $has_exclude_until)) {
        $unsubscribed = 'true';
    }

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
        'currencies'                => '',
        'country'                   => Locale::Country::code2country($test_client->residence),
        'mt5_loginids'              => join(',', sort($user->get_mt5_loginids)),
        landing_companies           => 'svg',
        available_landing_companies => 'labuan,svg',
        provider                    => 'email',
        unsubscribed                => $unsubscribed,
    };
    is_deeply $customer->traits, $expected_traits, 'Customer traits are set correctly';
}

$mock_brands->unmock_all;

subtest 'brand/offical app id validation' => sub {
    my $deriv           = Brands->new(name => 'deriv');
    my $binary          = Brands->new(name => 'binary');
    my ($deriv_app_id)  = $deriv->whitelist_apps->%*;
    my ($binary_app_id) = $binary->whitelist_apps->%*;

    ok BOM::Event::Services::Track::_validate_params($test_client->loginid,  'dummy', $deriv,  $deriv_app_id),  'Whitelisted app id and brand';
    ok !BOM::Event::Services::Track::_validate_params($test_client->loginid, 'dummy', $deriv,  $binary_app_id), 'Restricted app id or brand';
    ok BOM::Event::Services::Track::_validate_params($test_client->loginid,  'dummy', $binary, $binary_app_id), 'Whitelisted app id and brand';
    ok !BOM::Event::Services::Track::_validate_params($test_client->loginid, 'dummy', $binary, $deriv_app_id),  'Restricted app id or brand';

    subtest 'whitelist' => sub {
        # These events return 1 regardless of the brand / app_id
        my @whitelisted_events = (
            'p2p_order_created', 'p2p_order_buyer_has_paid', 'p2p_order_seller_has_released', 'p2p_order_cancelled',
            'p2p_order_expired', 'p2p_order_dispute',        'p2p_order_timeout_refund',
        );

        ok BOM::Event::Services::Track::_validate_brand($_, $binary, -1000), "$_ is whitelisted" foreach @whitelisted_events;
    };
};

$mock_segment->unmock_all;
$mock_mt5_groups->unmock_all;

done_testing();
