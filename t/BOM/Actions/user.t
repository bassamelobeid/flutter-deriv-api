use strict;
use warnings;

use Test::More;
use Test::Warnings qw(warning);
use Test::Fatal;
use Test::MockModule;
use Test::Deep;

use WebService::Async::Segment::Customer;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Email;
use BOM::Platform::Context qw(request);
use BOM::Platform::Context::Request;
use BOM::User;
use Time::Moment;
use Date::Utility;
use BOM::Platform::Locale qw/get_state_by_id/;
use BOM::Event::Process;

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

my @enabled_brands = ('deriv', 'binary');
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

subtest 'login event' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{login};
    my $req            = BOM::Platform::Context::Request->new(
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
    my $new_signin_activity = 0;

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            browser             => 'chrome',
            device              => 'Mac OS X',
            ip                  => '127.0.0.1',
            location            => 'Germany',
            new_signin_activity => $new_signin_activity,
            app_name            => 'it will be overwritten by request->app->{name}',
        }};

    my $result = $action_handler->($args)->get;
    ok $result, 'Success track result';
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
            browser             => 'chrome',
            device              => 'Mac OS X',
            ip                  => '127.0.0.1',
            location            => 'Germany',
            new_signin_activity => $new_signin_activity,
            app_name            => '',
            brand               => 'deriv',
        }
        },
        'identify context and properties is properly set.';

    $test_client->set_default_account('EUR');

    ok $action_handler->($args)->get, 'successful login track after setting currency';
    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client, 'EUR', $virtual_client->date_joined);

    undef @identify_args;
    undef @track_args;
    $args->{loginid} = $virtual_client->loginid;
    ok $action_handler->($args)->get, 'login triggered with virtual loginid';

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

    my $new_signin_activity_args = {
        loginid    => $test_client->loginid,
        properties => {
            browser             => 'firefox',
            device              => 'Mac OS X',
            ip                  => '127.0.0.1',
            location            => 'Germany',
            new_signin_activity => $new_signin_activity,
        }};
    $new_signin_activity = 1 if $args->{properties}->{browser} ne $new_signin_activity_args->{properties}->{browser};
    $new_signin_activity_args->{properties}->{new_signin_activity} = $new_signin_activity;
    undef @track_args;
    $result = $action_handler->($new_signin_activity_args)->get;
    ok $result, 'Success track result';
    ($customer, %args) = @track_args;
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'login',
        properties => {
            browser             => 'firefox',
            device              => 'Mac OS X',
            ip                  => '127.0.0.1',
            location            => 'Germany',
            new_signin_activity => $new_signin_activity,
            app_name            => '',
            brand               => 'deriv',
        }
        },
        'idenify context and properties is properly set after new signin activity.';

    subtest 'app name' => sub {
        my $mocked_oauth = Test::MockModule->new('BOM::Database::Model::OAuth');
        $mocked_oauth->mock(
            get_app_by_id => sub {
                my ($self, $app_id) = @_;

                return undef unless $app_id;
                return {
                    id   => $app_id,
                    name => "in the name of $app_id",
                };
            });
        $req = BOM::Platform::Context::Request->new(
            brand_name => 'deriv',
            language   => 'id',
            app_id     => 100
        );
        request($req);

        $result = $action_handler->($args)->get;
        ok $result, 'Success track result';
        ($customer, %args) = @track_args;
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
                browser             => 'chrome',
                device              => 'Mac OS X',
                ip                  => '127.0.0.1',
                location            => 'Germany',
                new_signin_activity => 0,
                app_name            => 'in the name of 100',
                brand               => 'deriv',
            }
            },
            'App name matches request->app_id.';

        $mocked_oauth->unmock_all;
    }
};

subtest 'user profile change event' => sub {
    my $action_handler = BOM::Event::Process::get_action_mappings()->{profile_change};
    my $virtual_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'VRTC',
        email       => 'test3@bin.com',
    });
    my $user = BOM::User->create(
        email          => $virtual_client->email,
        password       => "hello",
        email_verified => 1,
    );
    $user->add_client($virtual_client);
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test3@bin.com',
    });

    $user->add_client($test_client);
    $test_client->city('Ambon');
    $test_client->phone('+15417541233');
    $test_client->address_state('BAL');
    $test_client->address_line_1('street 1');
    $test_client->citizen('af');
    $test_client->place_of_birth('af');
    $test_client->residence('af');
    $test_client->save();

    my $args = {
        loginid    => $test_client->loginid,
        properties => {
            loginid          => $test_client->loginid,
            'updated_fields' => {
                'address_line_1' => 'street 1',
                'address_city'   => 'Ambon',
                'address_state'  => "BAL",
                'phone'          => '+15417541233',
                'citizen'        => 'af',
                'place_of_birth' => 'af',
                'residence'      => 'af'
            },
        }};
    undef @identify_args;
    undef @track_args;
    my $segment_response = Future->done(1);
    my $result           = $action_handler->($args)->get;
    ok $result, 'Success profile_change result';
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
        'identify context is properly set for profile change';

    ($customer, %args) = @track_args;
    test_segment_customer($customer, $test_client, '', $virtual_client->date_joined);
    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is_deeply \%args, {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'id'
        },
        event      => 'profile_change',
        properties => {
            brand   => 'deriv',
            loginid => $test_client->loginid,

            'address_line_1' => 'street 1',
            'address_city'   => 'Ambon',
            'address_state'  => "Balkh",
            'phone'          => '+15417541233',
            'citizen'        => 'Afghanistan',
            'place_of_birth' => 'Afghanistan',
            'residence'      => 'Afghanistan',
        }
        },
        'properties are set properly for user profile change event';

    subtest 'apply sanctions on profile change' => sub {
        my $sanctions_mock = Test::MockModule->new('BOM::Platform::Client::Sanctions');
        my $validate_mock  = Test::MockModule->new('Data::Validate::Sanctions');
        my %sanctions_args;
        my $sanctioned_info;
        my $user_mock = Test::MockModule->new('BOM::User');

        $sanctions_mock->mock(
            'check',
            sub {
                my $self = shift;
                %sanctions_args = @_;
                ok exists $sanctions_args{triggered_by}, 'triggered by param exists';
                return $sanctions_mock->original('check')->(($self, %sanctions_args));
            });

        my $user = BOM::User->create(
            email          => 'silly@ness.com',
            password       => "Coconut9009",
            email_verified => 1,
        );

        my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'silly@ness.com',
        });

        $user->add_client($test_client);
        $test_client->city('Ciudad del Este');
        $test_client->phone('+15417541233');
        $test_client->address_state('Acre');
        $test_client->address_line_1('some street');
        $test_client->citizen('br');
        $test_client->place_of_birth('br');
        $test_client->residence('br');
        $test_client->save();
        my $test_loginid = $test_client->loginid;

        # Sanctions shouldn't be called for address_line_1 updates
        subtest 'address_line_1 update' => sub {
            my $args = {
                loginid    => $test_loginid,
                properties => {
                    loginid          => $test_loginid,
                    'updated_fields' => {
                        'address_line_1' => 'other st',
                    },
                }};

            my $result = $action_handler->($args)->get;
            ok $result, 'Success profile_change result';
            is scalar keys %sanctions_args, 0, 'Sanctions not triggered for address_line_1 update';
        };

        # Sanctions called for update, but this data is innoffensive
        subtest 'clean profile update' => sub {
            $validate_mock->mock(
                'get_sanctioned_info',
                sub {
                    {matched => 0};
                });

            mailbox_clear();
            $args = {
                loginid    => $test_loginid,
                properties => {
                    loginid          => $test_loginid,
                    'updated_fields' => {
                        'first_name' => 'innoffensive name',
                    },
                }};

            $result = $action_handler->($args)->get;
            ok $result, 'Success profile_change result';
            cmp_deeply \%sanctions_args,
                {
                triggered_by => 'Triggered by profile update',
                comments     => 'Triggered by profile update'
                },
                'Sanctions check called with expected params';

            my $msg = mailbox_search(subject => qr/$test_loginid possible match in sanctions list - Triggered by profile update/);
            ok !$msg, 'No sanctions email sent';
        };

        # Sanctions called for update, the dirty one
        subtest 'dirty profile update' => sub {
            $user_mock->mock(
                'mt5_logins_with_group',
                sub {
                    {};
                });

            $validate_mock->unmock_all;
            $validate_mock->mock(
                'get_sanctioned_info',
                sub {
                    # I hope this 'private' mathod can be used in tests, this kindof simulate a sanction match
                    return Data::Validate::Sanctions::_possible_match(('some list', 'my forbidden name', 'some reason', '1990-10-10'));
                });

            mailbox_clear();
            $args = {
                loginid    => $test_loginid,
                properties => {
                    loginid          => $test_loginid,
                    'updated_fields' => {
                        'first_name'    => 'Yakeen',
                        'date_of_birth' => '1992-10-10'
                    },
                }};

            $result = $action_handler->($args)->get;
            ok $result, 'Success profile_change result';
            cmp_deeply \%sanctions_args,
                {
                triggered_by => 'Triggered by profile update',
                comments     => 'Triggered by profile update'
                },
                'Sanctions check called with expected params';
            my $msg = mailbox_search(subject => qr/$test_loginid possible match in sanctions list - Triggered by profile update/);
            ok $msg, 'Sanctions email sent';
            ok $msg->{body} =~ qr/Triggered by profile update/, 'Correct reason appended to email body';
            ok $msg->{body} !~ qr/MT5 Accounts/, 'Email does not show MT5 Accounts as user does not have any';
        };

        # Sanctions called for update, the dirty one, this time with mt5 accounts
        subtest 'dirty profile update with mt5 accounts' => sub {
            $user_mock->mock(
                'mt5_logins_with_group',
                sub {
                    {
                        'MTR10000' => 'real\svg',
                        'MTD9000'  => 'demo'
                    };
                });

            mailbox_clear();
            $args = {
                loginid    => $test_loginid,
                properties => {
                    loginid          => $test_loginid,
                    'updated_fields' => {
                        'first_name'    => 'Yakeen',
                        'date_of_birth' => '1992-10-10'
                    },
                }};

            $result = $action_handler->($args)->get;
            ok $result, 'Success profile_change result';
            my $msg = mailbox_search(subject => qr/$test_loginid possible match in sanctions list - Triggered by profile update/);
            ok $msg, 'Sanctions email sent';
            ok $msg->{body} =~ qr/Triggered by profile update/, 'Correct reason appended to email body';
            ok $msg->{body} =~ qr/MT5 Accounts/,                'Email does show MT5 Accounts';
        };

        $user_mock->unmock_all;
        $validate_mock->unmock_all;
        $sanctions_mock->unmock_all;
    };
};

sub test_segment_customer {
    my ($customer, $test_client, $currencies, $created_at) = @_;

    ok $customer->isa('WebService::Async::Segment::Customer'), 'Customer object type is correct';
    is $customer->user_id, $test_client->binary_user_id, 'User id is binary user id';
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
        'address'    => {
            street      => $test_client->address_line_1 . " " . $test_client->address_line_2,
            town        => $test_client->address_city,
            state       => BOM::Platform::Locale::get_state_by_id($test_client->state, $test_client->residence) // '',
            postal_code => $test_client->address_postcode,
            country     => Locale::Country::code2country($test_client->residence),
        },
        'currencies'                => $currencies,
        'country'                   => Locale::Country::code2country($test_client->residence),
        mt5_loginids                => join(',', sort($user->get_mt5_loginids)),
        landing_companies           => 'svg',
        available_landing_companies => 'labuan,svg',
        provider                    => 'email',
        unsubscribed                => $test_client->user->email_consent ? 'false' : 'true',
        },
        'Customer traits are set correctly';
}

done_testing();
