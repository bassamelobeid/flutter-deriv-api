use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;
use Test::Deep;
use Time::Moment;
use Date::Utility;
use Brands;

use WebService::Async::Segment::Customer;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Customer;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::Event::Actions::User;
use BOM::User;
use BOM::Service;
use BOM::Platform::Locale qw(get_state_by_id);

my $test_customer = BOM::Test::Customer->create({
        email          => 'test1@bin.com',
        password       => 'hello',
        email_verified => 1,
    },
    [{
            name        => 'CR',
            broker_code => 'CR',
        },
        {
            name        => 'VRTC',
            broker_code => 'VRTC',
        },
    ]);
my $test_client = $test_customer->get_client_object('CR');
my $user        = BOM::User->new(id => $test_customer->get_user_id());

my (@identify_args, @track_args, @transactional_args);

my $segment_response = Future->done(1);
my $mock_segment     = new Test::MockModule('WebService::Async::Segment::Customer');
my $mock_cio         = new Test::MockModule('WebService::Async::CustomerIO');
$mock_cio->redefine(
    'send_transactional' => sub {
        @transactional_args = @_;
        return Future->done(1);
    });

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
my $mock_app       = Test::MockModule->new('Brands::App');
$mock_app->mock(
    'is_whitelisted' => sub {
        my $self = shift;
        return (grep { $_ eq $self->brand_name } @enabled_brands);
    });
my $mock_brands = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $mock_mt5_groups = Test::MockModule->new('BOM::User');
$mock_mt5_groups->mock(
    mt5_logins_with_group => sub {
        return {};
    },
);

my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @metrics;
$dog_mock->mock(
    'stats_inc',
    sub {
        push @metrics, @_;
        return 1;
    });

subtest 'General event validation - filtering by brand' => sub {
    undef @identify_args;
    undef @track_args;

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id'
    );
    request($req);

    like exception { BOM::Event::Services::Track::track_event(event => 'login')->get },
        qr/login tracking triggered with an invalid or no loginid and no client. Please inform backend team if it continues to occur./,
        'Missing loginid exception';

    like exception { BOM::Event::Services::Track::track_event(event => 'login', loginid => 'CR1234')->get },
        qr/login tracking triggered with an invalid or no loginid and no client. Please inform backend team if it continues to occur./,
        'Invalid loginid exception';

    like exception { BOM::Event::Services::Track::track_event(event => 'UNKNOWN', loginid => $test_client->loginid)->get },
        qr/Unknown event <UNKNOWN> tracking request was triggered/,
        'Unknown event exception';

    $segment_response = Future->fail('dummy test failure');
    like exception { BOM::Event::Services::Track::track_event(event => 'login', loginid => $test_client->loginid)->get }, qr/dummy test failure/,
        'Correct exception raised';
    is @identify_args, 0, 'Segment identify is not invoked';
    ok @track_args, 'Segment track is invoked';
    my ($customer, %args) = @track_args;

    my $expected_args = {
        'context' => {
            'active' => 1,
            'app'    => {'name' => 'deriv'},
            'locale' => 'id'
        },
        'event'      => 'login',
        'properties' => {
            'brand'   => 'deriv',
            'lang'    => 'ID',
            'loginid' => $test_client->loginid,
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
    $expected_args->{properties} = {
        'brand'   => 'deriv',
        'lang'    => 'ID',
        'loginid' => $test_client->loginid,
    };
    is_deeply \%args, $expected_args, 'track request args are correct - invalid property filtered out';

    undef @track_args;
    ok BOM::Event::Services::Track::track_event(
        event                => 'login',
        client               => $test_client,
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

    subtest 'mt5 login id list' => sub {
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

        my $response = BOM::Service::user(
            context    => $test_customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $test_customer->get_user_id(),
            attributes => {email_consent => 1});
        is $response->{status}, 'ok', 'update email_consent ok';

        ok BOM::Event::Services::Track::track_event(
            event      => 'profile_change',
            client     => $test_client,
            properties => {
                updated_fields => {
                    email_consent => 1,
                },
                origin => 'client',
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
                event      => "profile_change",
                properties => {
                    updated_fields => {
                        email_consent => 1,
                    },
                    origin  => 'client',
                    brand   => 'deriv',
                    lang    => 'ID',
                    loginid => $test_client->loginid,
                },
            },
            'identify context is properly set for profile_change'
        );

        is $customer->{traits}->{unsubscribed}, 'false', '\'unsubscribed\' is set to false';
    };

    subtest 'Set unsubscribed to true on `account_closure` event' => sub {
        undef @track_args;
        undef @identify_args;

        my $response = BOM::Service::user(
            context    => $test_customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $test_customer->get_user_id(),
            attributes => {email_consent => 0});
        is $response->{status}, 'ok', 'update email_consent ok';

        ok BOM::Event::Services::Track::track_event(
            event      => 'account_closure',
            client     => $test_client,
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
                    lang           => 'ID',
                    loginid        => $test_client->loginid,
                },
            },
            'identify context is properly set for account_closure'
        );

        is $customer->{traits}->{unsubscribed}, 'true', '\'unsubscribed\' is set to true';
    };

    subtest 'Set unsubscribed to true on `email_subscription` event' => sub {
        undef @track_args;
        undef @identify_args;

        my $exclude_until = Date::Utility->new()->plus_time_interval('365d')->date;
        $test_client->set_exclusion->exclude_until($exclude_until);
        $test_client->save;
        ok BOM::Event::Services::Track::track_event(
            event      => 'email_subscription',
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
                event      => "email_subscription",
                properties => {
                    brand        => 'deriv',
                    unsubscribed => 1,
                    lang         => 'ID',
                    loginid      => $test_client->loginid,
                },
            },
            'identify context is properly set for email_subscription event'
        );

        test_segment_customer($customer, \%args);

        undef @track_args;
        undef @identify_args;

        my $response = BOM::Service::user(
            context    => $test_customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $test_customer->get_user_id(),
            attributes => {email_consent => 1});
        is $response->{status}, 'ok', 'update email_consent ok';

        ok BOM::Event::Services::Track::track_event(
            event      => 'profile_change',
            client     => $test_client,
            properties => {
                updated_fields => {
                    email_consent => 1,
                },
                origin => 'client',
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
                event      => "profile_change",
                properties => {
                    brand          => 'deriv',
                    updated_fields => {
                        email_consent => 1,
                    },
                    origin  => 'client',
                    lang    => 'ID',
                    loginid => $test_client->loginid,
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
                    lang     => 'ID',
                    loginid  => $test_client->loginid,
                },
            },
            'track args is properly set for cryptocashier payment_deposit'
        );

        undef @track_args;

        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_deposit',
            loginid    => $test_client->loginid,
            properties => {
                amount             => '10',
                currency           => 'USD',
                is_first_deposit   => 0,
                gateway_code       => 'payment_agent_transfer',
                is_agent_to_client => 0,
                loginid            => $test_client->loginid,
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
                    brand              => 'deriv',
                    amount             => '10',
                    currency           => 'USD',
                    lang               => 'ID',
                    is_first_deposit   => 0,
                    gateway_code       => 'payment_agent_transfer',
                    is_agent_to_client => 0,
                    loginid            => $test_client->loginid,
                },
            },
            'track args is properly set for payment agent payment_deposit'
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
                lang           => 'ID',
                loginid        => $test_client->loginid,
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
                    lang           => 'ID',
                    loginid        => $test_client->loginid,
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
                    lang     => 'ID',
                    loginid  => $test_client->loginid,
                },
            },
            'track args is properly set for cryptocashier payment_withdrawal'
        );

        undef @track_args;
        ok BOM::Event::Services::Track::track_event(
            event      => 'payment_withdrawal',
            loginid    => $test_client->loginid,
            properties => {
                amount             => '-10',
                currency           => 'USD',
                loginid            => $test_client->loginid,
                gateway_code       => 'payment_agent_transfer',
                is_agent_to_client => 0,
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
                    brand              => 'deriv',
                    amount             => '-10',
                    currency           => 'USD',
                    lang               => 'ID',
                    loginid            => $test_client->loginid,
                    gateway_code       => 'payment_agent_transfer',
                    is_agent_to_client => 0,
                },
            },
            'track args is properly set for payment agent payment_withdrawal'
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
                lang           => 'ID',
                loginid        => $test_client->loginid,
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
                    lang           => 'ID',
                    loginid        => $test_client->loginid,
                },
            },
            'track args is properly set for payment_withdrawal_reversal'
        );
    };

    subtest 'enforced "lang" as an event properties' => sub {
        undef @track_args;
        undef @identify_args;

        my $response = BOM::Service::user(
            context    => $test_customer->get_user_service_context(),
            command    => 'update_attributes',
            user_id    => $test_customer->get_user_id(),
            attributes => {preferred_language => 'RU'});
        is $response->{status}, 'ok', 'update preferred_language ok';

        ok BOM::Event::Services::Track::track_event(
            event      => 'email_subscription',
            loginid    => $test_client->loginid,
            properties => {
                unsubscribed => 1,
                lang         => 'ES',
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
                event      => "email_subscription",
                properties => {
                    unsubscribed => 1,
                    brand        => 'deriv',
                    lang         => 'ES',
                    loginid      => $test_client->loginid,
                },
            },
            'track lang args is correct'
        );
    };

    subtest 'transactional emails feature flag' => sub {
        undef @track_args;
        undef @identify_args;
        undef @transactional_args;
        my $args = {
            loginid    => $test_client->loginid,
            properties => {
                first_name => 'Aname',
                email      => 'any_email@anywhere.com',
                language   => 'EN',
            }};
        ok BOM::Event::Services::Track::track_event(
            event => 'request_change_email',
            $args->%*
        )->get;
        ok @track_args,          'Segment track is invoked by default';
        ok !@transactional_args, 'CIO transactional is not invoked by default';
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);
        undef @track_args;
        ok BOM::Event::Services::Track::track_event(
            event => 'request_change_email',
            $args->%*
        )->get;
        ok @track_args,         'Segment track is invoked';
        ok @transactional_args, 'CIO transactional is invoked';
        my (undef, $to_cmp) = @transactional_args;
        is_deeply(
            $to_cmp,
            {
                transactional_message_id => 'request_change_email',
                message_data             => {
                    loginid    => $test_client->loginid,
                    brand      => 'deriv',
                    lang       => 'RU',
                    first_name => 'Aname',
                    email      => 'any_email@anywhere.com',
                },
                to          => 'any_email@anywhere.com',
                identifiers => {id => $test_client->binary_user_id}
            },
            'correct transactional args'
        );
        is $metrics[0], 'bom-events.transactional_email.sent.success', 'success dd reported';
        undef @metrics;

        #test for failure dd metrics
        $mock_cio->redefine(
            'send_transactional' => sub {
                @transactional_args = @_;
                return Future->fail("API ERROR");
            });
        like exception {
            BOM::Event::Services::Track::track_event(
                event => 'request_change_email',
                $args->%*
            )->get
        }, qr{API ERROR};
        is $metrics[0], 'bom-events.transactional_email.sent.failure', 'failure dd reported';
    };

    subtest 'transactional emails mapper' => sub {
        undef @track_args;
        undef @identify_args;
        undef @transactional_args;
        my $mock_mapper = Test::MockModule->new('BOM::Event::Transactional::Mapper');
        $mock_mapper->mock(
            'get_event' => sub {
                return '';
            });
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);
        my $args = {
            loginid    => $test_client->loginid,
            properties => {
                first_name => 'Aname',
                email      => 'any_email@anywhere.com',
                language   => 'EN',
            }};
        #test for failure mapper failure.
        like exception {
            BOM::Event::Services::Track::track_event(
                event => 'request_change_email',
                $args->%*
            )->get
        }, qr{No match found for transactional Event};
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
        'salutation' => $test_client->salutation,
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
$mock_app->unmock_all;

subtest 'brand/offical app id validation' => sub {
    my $deriv  = Brands->new(name => 'deriv');
    my $binary = Brands->new(name => 'binary');
    # We can randomly pick any id if there's no overlapping ID for this purpose.
    # But, we have overlapping MT5 & DerivX in both binary and deriv config.
    my $deriv_app_id  = 19111;    # deriv bot
    my $binary_app_id = 1169;     # binary bot

    ok BOM::Event::Services::Track::_validate_event('dummy', $deriv,  $deriv_app_id),  'Whitelisted app id and brand';
    ok BOM::Event::Services::Track::_validate_event('dummy', $deriv,  $binary_app_id), 'Restricted app id or brand';
    ok BOM::Event::Services::Track::_validate_event('dummy', $binary, $binary_app_id), 'Whitelisted app id and brand';
    ok BOM::Event::Services::Track::_validate_event('dummy', $binary, $deriv_app_id),  'Restricted app id or brand';

    subtest 'whitelist' => sub {
        # These events return 1 regardless of the brand / app_id
        my @whitelisted_events = (
            'p2p_order_created', 'p2p_order_buyer_has_paid', 'p2p_order_seller_has_released', 'p2p_order_cancelled',
            'p2p_order_expired', 'p2p_order_dispute',        'p2p_order_timeout_refund',
        );

        ok BOM::Event::Services::Track::_validate_event($_, $binary, -1000), "$_ is whitelisted" foreach @whitelisted_events;
    };
};

subtest 'transactional emails and the email argument' => sub {
    my %track = %{BOM::Event::Services::Track::}{qw/duplicated_document_account_closed/};

    # this test ensures that every transactional event has a defined email within its properties
    # otherwise you will hit a nasty hidden `Missing required attribute: to`

    for my $method (keys %track) {
        next unless BOM::Event::Services::Track::_is_transactional($method);

        my $valid_properties = BOM::Event::Services::Track::valid_properties(
            $method,
            {
                email => 'test@test.com',
                dirty => 'stuff'
            });

        cmp_deeply $valid_properties,
            {
            email => 'test@test.com',
            },
            "Transactional event $method has a valid email property, also dirty stuff is filtered out";
    }
};

$mock_segment->unmock_all;
$mock_mt5_groups->unmock_all;
$mock_cio->unmock_all;

done_testing();
