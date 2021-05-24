use strict;
use warnings;
use utf8;

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

my @emit_args;
my $mock_emitter = new Test::MockModule('BOM::Platform::Event::Emitter');
$mock_emitter->mock('emit', sub { @emit_args = @_ });

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
    undef @emit_args;
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

    ok !@emit_args, 'No event is emitted';

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
            undef @emit_args;
            my $result = $action_handler->($args)->get;
            ok $result, 'Success profile_change result';
            is scalar keys %sanctions_args, 0, 'Sanctions not triggered for address_line_1 update';

            ok !@emit_args, 'No false info event emitted for address update';
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
                'get_sanctioned_info' => sub {
                    return {
                        matched      => 1,
                        matched_args => {
                            name      => 'my forbidden name',
                            dob_epoch => 655516800
                        },
                        list    => 'EU-Sanctions',
                        comment => 'some reason',
                    };
                },
                last_updated => sub { return DateTime->now },
            );

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

    subtest 'update_status_after_auth_fa called for tax and mifir_id updates' => sub {
        my $mock_client          = Test::MockModule->new('BOM::User::Client');
        my $update_status_called = 0;
        $mock_client->mock('update_status_after_auth_fa', sub { $update_status_called += 1 });

        my $args = {
            loginid    => $test_client->loginid,
            properties => {
                loginid          => $test_client->loginid,
                'updated_fields' => {
                    'first_name' => 'Yakeen',
                    'last_name'  => 'Doodle'
                },
            }};

        $action_handler->($args)->get();
        is $update_status_called, 0, 'update_status_after_auth_fa is not called when name is updated';

        for my $field (qw/tax_residence tax_identification_number mifir_id/) {
            $args->{properties}->{updated_fields} = {$field => 1};
            $update_status_called = 0;
            $action_handler->($args)->get();
            is $update_status_called, 1, "update_status_after_auth_fa is called  when $field is updated";
        }

        $mock_client->unmock_all;
    };
};

subtest 'false profile info' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'en'
    );
    request($req);

    my $event_handler = BOM::Event::Process::get_action_mappings()->{verify_false_profile_info};

    my $client_cr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'MLT',
    });

    my $test_user = BOM::User->create(
        email          => 'false_profile@deriv.com',
        password       => "hello",
        email_verified => 1,
    );

    $test_user->add_client($client_cr);
    $test_user->add_client($client_mlt);

    my @mail_box;
    my $mock_email = Test::MockModule->new('BOM::Event::Actions::User');
    $mock_email->mock('send_email' => sub { push @mail_box, shift; });

    my $args = {
        loginid => $client_cr->loginid,
    };

    my @test_set = ({
            field      => 'first_name',
            'value'    => 'bcd',
            result     => 'fake',
            label      => 'all-consonant latin ascii name',
            email_sent => 1
        },
        {
            field      => 'first_name',
            'value'    => 'asdf',
            result     => 0,
            label      => 'latin ascii name with vowels',
            email_sent => 0
        },
        {
            field      => 'last_name',
            'value'    => 'محمد',
            result     => 'fake',
            label      => 'arabic unicode name without vowels',
            email_sent => 1
        },
        {
            field      => 'last_name',
            'value'    => 'احمد',
            result     => 'fake',
            label      => 'arabic name is locked even with vowels (unless it is seen before)',
            email_sent => 1
        },
        {
            field      => 'first_name',
            'value'    => 'лкс',
            result     => 'fake',
            label      => 'cyrillic unicode name without vowels',
            email_sent => 1
        },
        {
            field      => 'first_name',
            'value'    => 'Алексе́й',
            result     => 0,
            label      => 'cyrillic unicode name with vowels',
            email_sent => 0
        },
        {
            field      => 'last_name',
            'value'    => 'company',
            result     => 'corporate',
            label      => 'corporate names are not banned',
            email_sent => 1
        },
        {
            field      => 'address_line_1',
            'value'    => 'bcd',
            result     => 0,
            label      => 'address field is not checked',
            email_sent => 0
        },
        {
            field      => 'secret_answer',
            'value'    => 'bcd',
            result     => 0,
            label      => 'secret_answer is not checked',
            email_sent => 0
        },
    );

    my $brand = Brands->new(name => 'deriv');
    for my $test_case (@test_set) {
        $args = {
            loginid             => $client_cr->loginid,
            $test_case->{field} => $test_case->{value}};
        $event_handler->($args);
        test_fake_name($test_case, $client_cr,  \@mail_box, $brand);
        test_fake_name($test_case, $client_mlt, \@mail_box, $brand);

        $_->status->clear_cashier_locked for $test_user->clients;
        $_->status->clear_unwelcome      for $test_user->clients;
        undef @mail_box;
    }

    subtest 'corner cases' => sub {
        my $mock_client = Test::MockModule->new('BOM::User::Client');

        # accounts won't be locked if POI is verified
        $mock_client->mock(get_poi_status => sub { return 'verified' });
        $args = {
            loginid    => $client_cr->loginid,
            first_name => 'BBBBBB',
            last_name  => 'DDDDDD'
        };
        $event_handler->($args);
        test_fake_name({
                result     => 0,
                value      => 'BBBBBB',
                label      => 'no lock after POI',
                email_sent => 0
            },
            $client_cr,
            \@mail_box,
            $brand
        );
        $mock_client->unmock('get_poi_status');

        # if account has deposits, the account will be cashier-locked
        $mock_client->mock(has_deposits => sub { return 1 });
        $event_handler->($args);
        test_fake_name({
                result     => 'fake',
                value      => 'BBBBBB',
                label      => 'accounts with deposits are cashier_locked',
                status     => 'cashier_locked',
                reason     => 'fake profile info - pending POI',
                email_sent => 1
            },
            $client_cr,
            \@mail_box,
            $brand
        );
        $_->status->clear_cashier_locked for $test_user->clients;
        undef @mail_box;
        $mock_client->unmock('has_deposits');

        # Sibling is locked with a dummy reason -> email will be sent
        $client_cr->status->upsert('unwelcome', 'system', 'dummy reason');
        $event_handler->($args);
        undef $client_cr->{status};
        is $client_cr->status->reason('unwelcome'), 'dummy reason', 'CR unwelcome is not changed';
        ok !$client_cr->status->cashier_locked, 'CR client is not cashier-locked';
        test_fake_name({
                result     => 'fake',
                value      => 'BBBBBB',
                label      => 'CR was already locked (with dummy reason)',
                status     => 'unwelcome',
                email_sent => 1
            },
            $client_mlt,
            \@mail_box,
            $brand
        );
        $_->status->clear_unwelcome for $test_user->clients;
        undef @mail_box;

        # Sibling is locked with false-name reason -> no email is sent
        $client_cr->status->upsert('unwelcome', 'system', 'fake profile info - pending POI');
        $event_handler->($args);
        ok !$client_cr->status->cashier_locked, 'CR client is not cashier-locked';
        test_fake_name({
                result     => 'fake',
                value      => 'BBBBBB',
                label      => 'CR was already locked with false-name reason',
                status     => 'unwelcome',
                email_sent => 0
            },
            $client_mlt,
            \@mail_box,
            $brand
        );
        $_->status->clear_unwelcome for $test_user->clients;
        undef @mail_box;

        $mock_client->unmock_all;
    };

    $mock_email->unmock_all;
};

sub test_fake_name {
    my ($test_case, $client, $emails, $brand) = @_;

    my %reason = (
        corporate => 'potential corporate account - pending POI',
        fake      => 'fake profile info - pending POI',
    );
    my $loginid = $client->loginid;
    undef $client->{status};

    my $status = $test_case->{status} // 'unwelcome';
    if ($test_case->{result}) {
        ok $reason{$test_case->{result}}, "Test result is <$test_case->{result}> - $test_case->{label} -$loginid";
        ok $client->status->$status, "client is $status - $test_case->{label}";
        is $client->status->$status->{reason}, $reason{$test_case->{result}}, "correct  status reason - $test_case->{label} -$loginid";

    } else {
        ok !$client->status->unwelcome,      "client is not unwelcome - $test_case->{label} -$loginid";
        ok !$client->status->cashier_locked, "client is not locked - $test_case->{label} - $loginid";
    }

    if ($test_case->{email_sent}) {
        is scalar @$emails, 1, 'Just one email is sent - system does not sent duplicate emails';
        is_deeply $emails->[0],
            {
            from          => $brand->emails('no-reply'),
            to            => $client->email,
            subject       => "Account verification",
            template_name => 'authentication_required',
            template_args => {
                l                  => \&BOM::Platform::Context::localize,
                name               => $client->first_name,
                title              => "Account verification",
                authentication_url => $brand->authentication_url,
                profile_url        => $brand->profile_url,
            },
            use_email_template    => 1,
            email_content_is_html => 1,
            use_event             => 0
            },
            'email args are correct';
    } else {
        ok !@$emails, "no email is sent - $test_case->{label} - $loginid";
    }
}

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

$mock_segment->unmock_all;
$mock_emitter->unmock_all;
$mock_brands->unmock_all;

done_testing();
