use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::Fatal;
use Test::MockTime qw(:all);
use Time::Moment;

use Log::Any::Test;
use Log::Any                                   qw($log);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Event::Actions::MT5;
use Test::MockModule;
use BOM::User;
use BOM::User::Client;
use DataDog::DogStatsd::Helper;
use BOM::Platform::Context qw(localize request);
use BOM::Event::Process;
use BOM::Test::Email   qw(mailbox_clear mailbox_search);
use BOM::User::Utility qw(parse_mt5_group);

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;

my (@identify_args, @track_args);
my $mock_segment = new Test::MockModule('WebService::Async::Segment::Customer');
$mock_segment->redefine(
    'identify' => sub {
        @identify_args = @_;
        return Future->done(1);
    },
    'track' => sub {
        push @track_args, \@_;
        return Future->done(1);
    });
my @enabled_brands = ('deriv', 'binary');
my $mock_brands    = Test::MockModule->new('Brands');
$mock_brands->mock(
    'is_track_enabled' => sub {
        my $self = shift;
        return (grep { $_ eq $self->name } @enabled_brands);
    });

my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'CR',
});
my $user = BOM::User->create(
    email          => $test_client->email,
    password       => "hello",
    email_verified => 1,
);
$user->add_client($test_client);
$user->add_loginid('MT1000');

my $mocked_mt5 = Test::MockModule->new('BOM::MT5::User::Async');
$mocked_mt5->mock('update_user', sub { Future->done({}) });

my $mocked_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');
my @emitter_args;
$mocked_emitter->mock(
    'emit',
    sub {
        @emitter_args = @_;
        my $request      = request();
        my $context_info = {
            brand_name => $request->brand->name,
            language   => $request->language,
            app_id     => $request->app_id,
        };
        push @emitter_args, $context_info;
        return 1;
    });

my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @datadog_args;
$mocked_datadog->mock('stats_inc', sub { @datadog_args = @_ });

my $mocked_user                = Test::MockModule->new('BOM::User');
my $mocked_user_client         = Test::MockModule->new('BOM::User::Client');
my $mocked_rule_engine         = Test::MockModule->new('BOM::Rules::Engine');
my $mocked_mt5_events          = Test::MockModule->new('BOM::Event::Actions::MT5');
my $mocked_user_client_account = Test::MockModule->new('BOM::User::Client::Account');

subtest 'test unrecoverable error' => sub {
    $mocked_mt5->mock('get_user', sub { Future->done({error => 'Not found'}) });
    is(BOM::Event::Actions::MT5::sync_info({loginid => $test_client->loginid}), 0, 'return 0 because there is error');
    ok(!@emitter_args, 'no new event emitted');
    like($datadog_args[0], qr/unrecoverable_error/, 'call datadog for this error');
};

subtest 'test non unrecoverable  error', sub {
    $mocked_mt5->mock('get_user', sub { Future->done({error => 'fake error'}) });
    my $count       = 0;
    my $cached_args = {loginid => $test_client->loginid};
    @datadog_args = ();
    # It is impossible to try 10+ times; It need only a number that big enough
    for (1 .. 10) {
        @emitter_args = ();
        is(BOM::Event::Actions::MT5::sync_info($cached_args), 0, 'return 0 because there is error');
        $count++;
        last unless (@emitter_args);
        ok(@emitter_args, 'new event emitted');
        $cached_args = $emitter_args[1];
        is($cached_args->{tried_times}, $count, 'emitter is called with tried_times 1 ');
        ok(!@datadog_args, 'No datadog called');
    }

    is($count, 5, 'tried 5 times');
    ok(@datadog_args, 'datadog called');
    like($datadog_args[0], qr/retried_error/, 'datadog called');
};

subtest 'no error' => sub {
    @datadog_args = ();
    $mocked_mt5->mock('get_user', sub { Future->done({}) });
    @emitter_args = ();
    is(BOM::Event::Actions::MT5::sync_info({loginid => $test_client->loginid}), 1, 'return 1 because there is no error');
    ok(!@datadog_args, 'no datadog called');
    ok(!@emitter_args, 'no event emitted');
};

subtest 'mt5 track event' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id',
        app_id     => $app_id,
    );
    request($req);

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test@bin.com',
    });

    my $user = BOM::User->create(
        email          => $test_client->email,
        password       => "hello",
        email_verified => 1,
    );
    $user->add_client($test_client);
    $user->add_loginid('MTR90000');

    subtest 'mt5 signup track' => sub {
        my $args = {
            loginid            => $test_client->loginid,
            'account_type'     => 'gaming',
            'language'         => 'EN',
            'mt5_group'        => 'real\\p02_ts02\\synthetic\\svg_std_usd',
            'mt5_server'       => 'p02_ts02',
            'mt5_login_id'     => 'MTR90000',
            'language'         => 'EN',
            'cs_email'         => 'test_cs@bin.com',
            'sub_account_type' => 'financial'
        };
        undef @identify_args;
        undef @track_args;
        undef @emitter_args;

        my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{new_mt5_signup};
        my $result         = $action_handler->($args);
        ok $result, 'Success mt5 new account result';
        BOM::Event::Process->new(category => 'track')->process({
                type    => $emitter_args[0],
                details => $emitter_args[1],
                context => $emitter_args[2]})->get;

        is scalar @track_args, 1;
        my ($customer, %args) = $track_args[0]->@*;
        my $mt5_details = parse_mt5_group($args->{mt5_group});
        my $type_label  = $mt5_details->{market_type};
        $type_label .= '_stp' if $mt5_details->{sub_account_type} eq 'stp';

        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'mt5_signup',
            properties => {
                loginid                => $test_client->loginid,
                account_type           => 'gaming',
                language               => 'EN',
                mt5_group              => 'real\\p02_ts02\\synthetic\\svg_std_usd',
                mt5_loginid            => 'MTR90000',
                sub_account_type       => 'financial',
                client_first_name      => $test_client->first_name,
                type_label             => ucfirst $type_label,
                mt5_integer_id         => '90000',
                brand                  => 'deriv',
                mt5_server_location    => 'South Africa',
                mt5_server_region      => 'Africa',
                mt5_server             => 'p02_ts02',
                mt5_server_environment => 'Deriv-Server-02',
                lang                   => 'ID',
                mt5_dashboard_url      => 'https://app.deriv.com/mt5?lang=id',
                live_chat_url          => 'https://deriv.com/id/?is_livechat_open=true'
            }
            },
            'properties are set properly for new mt5 account event';

        is scalar(@identify_args), 0, 'Identify is not triggered';

        undef @track_args;

        $args->{mt5_login_id} = '';
        like exception { $action_handler->($args); }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';
    };

    subtest 'mt5 seychelles group signup track' => sub {
        my $args = {
            loginid            => $test_client->loginid,
            'account_type'     => 'gaming',
            'language'         => 'EN',
            'mt5_group'        => 'real\\p02_ts02\\synthetic\\seychelles_ib_usd',
            'mt5_server'       => 'p02_ts02',
            'mt5_login_id'     => 'MTR90000',
            'language'         => 'EN',
            'cs_email'         => 'test_cs@bin.com',
            'sub_account_type' => 'financial'
        };
        undef @identify_args;
        undef @track_args;
        undef @emitter_args;

        my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{new_mt5_signup};
        my $result         = $action_handler->($args);
        ok $result, 'Success mt5 new account result';
        BOM::Event::Process->new(category => 'track')->process({
                type    => $emitter_args[0],
                details => $emitter_args[1],
                context => $emitter_args[2]})->get;

        is scalar @track_args, 1;
        my ($customer, %args) = $track_args[0]->@*;
        my $mt5_details = parse_mt5_group($args->{mt5_group});
        my $type_label  = $mt5_details->{market_type};
        $type_label .= '_stp' if $mt5_details->{sub_account_type} eq 'stp';

        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'mt5_signup',
            properties => {
                loginid                => $test_client->loginid,
                account_type           => 'gaming',
                language               => 'EN',
                mt5_group              => 'real\\p02_ts02\\synthetic\\seychelles_ib_usd',
                mt5_loginid            => 'MTR90000',
                sub_account_type       => 'financial',
                client_first_name      => $test_client->first_name,
                type_label             => ucfirst $type_label,
                mt5_integer_id         => '90000',
                brand                  => 'deriv',
                mt5_server_location    => 'South Africa',
                mt5_server_region      => 'Africa',
                mt5_server             => 'p02_ts02',
                mt5_server_environment => 'Deriv-Server-02',
                lang                   => 'ID',
                mt5_dashboard_url      => 'https://app.deriv.com/mt5?lang=id',
                live_chat_url          => 'https://deriv.com/id/?is_livechat_open=true'
            }
            },
            'properties are set properly for new mt5 account event';

        is scalar(@identify_args), 0, 'Identify is not triggered';

        undef @track_args;

        $args->{mt5_login_id} = '';
        like exception { $action_handler->($args)->get; }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';
    };

    subtest 'mt5 password change' => sub {
        my $args = {
            loginid => $test_client->loginid,
        };
        undef @track_args;

        my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{mt5_password_changed};

        like exception { $action_handler->($args)->get; }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';

        $args->{mt5_loginid} = 'MT90000';
        my $result = $action_handler->($args)->get;
        ok $result, 'Success mt5 password change result';

        is scalar @track_args, 1;
        my ($customer, %args) = $track_args[0]->@*;
        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'mt5_password_changed',
            properties => {
                loginid       => $test_client->loginid,
                'mt5_loginid' => 'MT90000',
                brand         => 'deriv',
                lang          => 'ID'
            }
            },
            'properties are set properly for mt5 password change event';
    };

    subtest 'mt5 color change' => sub {
        my $args = {};

        my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{mt5_change_color};

        like exception { $action_handler->($args)->get; }, qr/Loginid is required/, 'correct exception when loginid is missing';

        $args->{loginid} = 'MT90000';
        $args->{color}   = 16711680;

        $mocked_mt5->mock('get_user', sub { Future->fail({code => "NotFound"}) });
        $mocked_user->mock('new', sub { bless {id => 1}, 'BOM::User' });

        my $response =
            index($action_handler->($args)->{failure}[0], 'Account MT90000 not found among the active accounts, changed the status to archived');

        is $response, 0, 'correct exception when MT5 account is not found';

        $mocked_mt5->mock('get_user',    sub { Future->done({login => "MT90000", email => 'test123@test.com'}) });
        $mocked_mt5->mock('update_user', sub { Future->done({login => "MT90000", color => 123}) });

        like exception { $action_handler->($args)->get; }, qr/Could not change client MT90000 color to 16711680/,
            'correct exception when failed to update color field';

        $mocked_mt5->mock('update_user', sub { Future->done({login => "MT90000", color => 16711680}) });
        my $result = $action_handler->($args)->get;
        ok $result, 'Success mt5 color change result';

        $mocked_mt5->unmock('get_user');
        $mocked_user->unmock('new');
    };

    subtest 'mt5 store tranactions' => sub {
        my $args = {
            loginid         => $test_client->loginid,
            'group'         => 'real\p01_ts04\synthetic\vanuatu_std_usd',
            'mt5_server'    => 'p01_ts04',
            'mt5_id'        => 'MTR90301',
            'action'        => 'deposit',
            'amount_in_USD' => 400
        };

        mailbox_clear();
        my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{store_mt5_transaction};
        my $result         = $action_handler->($args);
        ok $result, 'Success mt5 store transactions result';
        my $msg = mailbox_search(subject => qr/VN - International currency transfers reporting obligation/);
        ok !$msg, 'no email was sent';

        $args->{amount_in_USD} = 7800;
        $action_handler        = BOM::Event::Process->new(category => 'generic')->actions->{store_mt5_transaction};
        $result                = $action_handler->($args);
        ok $result, 'Success mt5 store transactions result';
        $msg = mailbox_search(subject => qr/VN - International currency transfers reporting obligation/);
        cmp_deeply(
            $msg->{to},
            [BOM::Platform::Context::request()->brand()->emails('compliance_alert')],
            qq/Email should send to the compliance team./
        );
        ok $msg, 'email was sent when total amount exceeded 8000';
        mailbox_clear();
        $args->{amount_in_USD} = 7800;
        $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{store_mt5_transaction};
        ok $result, 'Success mt5 store transactions result';
        $msg = mailbox_search(subject => qr/VN - International currency transfers reporting obligation/);
        ok !$msg, 'no email was sent, counter reset';
    };
};

subtest 'sanctions' => sub {
    my $mock_sanctions = Test::MockModule->new('BOM::Platform::Client::Sanctions');
    my @sanct_args;
    $mock_sanctions->mock(
        'check' => sub {
            @sanct_args = @_;
        });

    my $mock_company = Test::MockModule->new('LandingCompany');
    my $lc_actions;
    $mock_company->mock(
        'actions' => sub {
            return $lc_actions;
        });

    my $args = {
        loginid            => $test_client->loginid,
        'account_type'     => 'gaming',
        'language'         => 'EN',
        'mt5_group'        => 'real\svg',
        'mt5_server'       => 'real02',
        'mt5_login_id'     => 'MTR90000',
        'language'         => 'EN',
        'cs_email'         => 'test_cs@bin.com',
        'sub_account_type' => 'financial'
    };

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{new_mt5_signup};
    is $action_handler->($args), 1, 'Success mt5 new account result';

    is scalar @sanct_args, 0, 'sanctions are not included in signup actions';

    $lc_actions = {signup => [qw(sanctions)]};
    is $action_handler->($args), 1,                                  'Success mt5 new account result';
    is scalar @sanct_args,       5,                                  'sanction check is called, because it is included in signup actions';
    is ref($sanct_args[0]),      'BOM::Platform::Client::Sanctions', 'Sanctions object type is correct';
    ok $sanct_args[0]->recheck_authenticated_clients, 'recheck for authenticated clients is enabled';
    shift @sanct_args;
    is_deeply \@sanct_args,
        [
        'comments'     => 'Triggered by a new MT5 signup - MT5 loginid: MTR90000 and MT5 group: real\svg',
        'triggered_by' => "MTR90000 (real\\svg) signup"
        ],
        'Sanctions checked with correct comment';

    $mock_sanctions->unmock_all;
};

subtest 'mt5 inactive notification' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
    );
    request($req);
    my $args = {
        email    => '',
        name     => 'Matt Smith',
        accounts => {
            4 => [{
                    loginid => 'MT900000',
                    type    => 'demo financial'
                },
                {
                    loginid => 'MT900002',
                    type    => 'real financial'
                }
            ],
            14 => [{
                    loginid => 'MT900001',
                    type    => 'real gaming'
                }
            ],
        }};
    my $now   = Time::Moment->now();
    my $today = Time::Moment->new(
        year  => $now->year,
        month => $now->month,
        day   => $now->day_of_month
    );

    undef @identify_args;
    undef @track_args;

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{mt5_inactive_notification};

    like exception { $action_handler->($args)->get; }, qr/invalid email address/i, 'correct exception when mt5 loginid is missing';
    is scalar @track_args,    0, 'Track is not triggered';
    is scalar @identify_args, 0, 'Identify is not triggered';

    $args->{email} = $test_client->{email};
    my $result = $action_handler->($args)->get;
    ok $result, 'Success event result';

    is scalar @track_args, 2, 'Track is called twice';
    my ($customer, %args) = $track_args[0]->@*;
    isa_ok $customer, 'WebService::Async::Segment::Customer', 'First arg is a customer';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'EN'
        },
        event      => 'mt5_inactive_notification',
        properties => {
            email        => $test_client->email,
            name         => 'Matt Smith',
            closure_date => $today->plus_days(4)->epoch,
            accounts     => $args->{accounts}->{4},
            brand        => 'deriv',
            lang         => 'EN',
            loginid      => $test_client->loginid,
        }
        },
        'properties of the first event tracking is correct';

    ($customer, %args) = $track_args[1]->@*;
    isa_ok $customer, 'WebService::Async::Segment::Customer', 'First arg of the second track call is a customer';
    is_deeply \%args,
        {
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'EN'
        },
        event      => 'mt5_inactive_notification',
        properties => {
            email        => $test_client->email,
            name         => 'Matt Smith',
            closure_date => $today->plus_days(14)->epoch,
            accounts     => $args->{accounts}->{14},
            brand        => 'deriv',
            lang         => 'EN',
            loginid      => $test_client->loginid,
        }
        },
        'properties of the second event tracking is correct';

    is scalar(@identify_args), 0, 'Identify is not triggered';

    undef @track_args;

    $args->{accounts}->{14} = {
        loginid => 'MT900001',
        type    => 'real gaming'
    };

    undef @identify_args;
    undef @track_args;

};

subtest 'mt5 inactive account closed' => sub {

    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        app_id     => $app_id,
        language   => 'ES',
    );
    request($req);

    my $args = {
        email        => '',
        transferred  => 'CR12345',
        mt5_accounts => [{
                login => 'MT900000',
                type  => 'demo financial',
                name  => 'Bob Doe',
            },
            {
                login => 'MT900002',
                type  => 'real financial',
                name  => 'Bob Doe',
            }
        ],
    };

    my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{mt5_inactive_account_closed};

    like exception { $action_handler->($args) }, qr/invalid email address/i, 'correct exception when mt5 loginid is missing';

    undef @identify_args;
    undef @track_args;

    $args->{email} = $test_client->{email};
    my $result = $action_handler->($args)->get;
    ok $result, 'Success event result';

    my (undef, %tracked) = $track_args[0]->@*;

    is_deeply \%tracked,
        {
        event   => 'mt5_inactive_account_closed',
        context => {
            active => 1,
            app    => {name => 'deriv'},
            locale => 'ES',
        },
        properties => {
            name          => 'Bob Doe',
            mt5_accounts  => $args->{mt5_accounts},
            brand         => 'deriv',
            lang          => 'ES',
            loginid       => $test_client->loginid,
            live_chat_url => request->brand->live_chat_url({language => 'ES'}),
        },
        },
        'track event properties correct';
};

subtest 'mt5 account closure report' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
    );
    request($req);
    my $args = {
        reports => [{
                date                   => '2021-07-15',
                mt5_account            => 'MTD123',
                mt5_balance            => 0,
                mt5_account_currency   => 'USD',
                deriv_account          => 'CR321',
                deriv_account_currency => 'USD',
                transferred_amount     => 0,
            }]};

    mailbox_clear();

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{mt5_inactive_account_closure_report};
    $action_handler->($args);

    my $email = mailbox_search(
        email   => 'i-payments@deriv.com',
        subject => qr/MT5 account closure report/
    );

    ok $email, 'Account closure report email sent';
    like $email->{body}, qr/MT5 account closure report is attached/, 'corrent content';
};

subtest 'mt5 deriv auto rescind' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id',
        app_id     => $app_id,
    );
    request($req);

    my $auto_rescind_test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'testrescind@test.com',
    });

    my $sample_mt5_user = {
        address       => "ADDR 1",
        agent         => 0,
        balance       => "0.0",
        city          => "Cyber",
        company       => "",
        country       => "Indonesia",
        email         => $auto_rescind_test_client->email,
        group         => "real\\p01_ts03\\synthetic\\svg_std_usd\\03",
        leverage      => 500,
        login         => "MTR10000",
        name          => "QA script testrescindfVz",
        phone         => "+62417591703",
        phonePassword => undef,
        rights        => 481,
        state         => "",
        zipCode       => undef,
    };

    my $sample_bom_user = {
        email              => $auto_rescind_test_client->email,
        preferred_language => 'en'
    };

    my $sample_bom_user_client = {
        currency => 'USD',
    };

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{mt5_deriv_auto_rescind};
    my $action_get     = sub { $action_handler->(shift)->get };

    my %mt5_event_mock = (
        convert_currency => sub {
            $mocked_mt5_events->mock(
                'convert_currency',
                shift // sub {
                    my ($amount, $from_currency, $to_currency) = @_;
                    my $convert_rate = 1;

                    #Assumption for test, from_currency always USD
                    $convert_rate = 0.000043 if $to_currency eq 'BTC';
                    $convert_rate = 0.98     if $to_currency eq 'EUR';

                    return ($amount) * $convert_rate;
                });
        },
        financialrounding => sub {
            $mocked_mt5_events->mock(
                'financialrounding',
                shift // sub {
                    my ($type, $currency, $amount) = @_;
                    return $amount;
                });
        },
        record_mt5_transfer => sub {
            $mocked_mt5_events->mock('_record_mt5_transfer', shift // sub { 1 });
        },
    );

    my %mt5_mock = (
        get_user => sub {
            $mocked_mt5->mock('get_user', shift // sub { Future->done($sample_mt5_user) });
        },
        get_group => sub {
            $mocked_mt5->mock('get_group', shift // sub { Future->done({currency => 'USD'}) });
        },
        get_open_positions_count => sub {
            $mocked_mt5->mock('get_open_positions_count', shift // sub { Future->done({total => 0}) });
        },
        get_open_orders_count => sub {
            $mocked_mt5->mock('get_open_orders_count', shift // sub { Future->done({total => 0}) });
        },
        user_balance_change => sub {
            $mocked_mt5->mock('user_balance_change', shift // sub { Future->done({status => 1}) });
        },
        update_user => sub {
            $mocked_mt5->mock('update_user', shift // sub { Future->done({status => 1}) });
        },
        user_archive => sub {
            $mocked_mt5->mock('user_archive', shift // sub { Future->done({status => 1}) });
        },
    );

    my %bom_user_mock = (
        new => sub {
            $mocked_user->mock('new', shift // sub { bless $sample_bom_user, 'BOM::User' });
        },
        bom_real_loginids => sub {
            $mocked_user->mock('bom_real_loginids', shift // sub { ('CR90000') });
        },
    );

    my %bom_user_client_mock = (
        new => sub {
            $mocked_user_client->mock('new', shift // sub { bless $sample_bom_user_client, 'BOM::User::Client' });
        },
        currency => sub {
            $mocked_user_client->mock('currency', shift // sub { 'USD' });
        },
        validate_payment => sub {
            $mocked_user_client->mock('validate_payment', shift // sub { 1 });
        },
        status => sub {
            $mocked_user_client->mock('status', shift // sub { bless {disabled => 0}, 'BOM::User::Client::Status' });
        },
        payment_mt5_transfer => sub {
            $mocked_user_client->mock('payment_mt5_transfer', shift // sub { bless {payment_id => '123'}, 'BOM::User::Client::Account' });
        },
        db => sub {
            $mocked_user_client->mock(
                'db',
                shift // sub {
                    bless {
                        dbic => sub { 1 }
                        },
                        'BOM::User::Client';
                });
        },
        dbic => sub {
            $mocked_user_client->mock('dbic', shift // sub { 1 });
        },
    );

    my %bom_user_client_account_mock = (
        payment_id => sub {
            $mocked_user_client_account->mock('payment_id', shift // sub { '123' });
        },
    );

    my %bom_rule_engine_mock = (
        new => sub {
            $mocked_rule_engine->mock('new', shift // sub { bless {}, 'BOM::Rules::Engine' });
        },
        apply_rules => sub {
            $mocked_rule_engine->mock('apply_rules', shift // sub { 1 });
        },
    );

    my $mt5_deriv_auto_rescind_mock_set = sub {
        $mt5_mock{get_user}->();
        $bom_user_mock{new}->();
        $bom_user_mock{bom_real_loginids}->(sub { ('CR90000') });
    };

    my $mt5_deriv_auto_rescind_process_mock_set = sub {
        $bom_user_client_mock{new}->();
        $bom_user_client_mock{currency}->();
        $mt5_mock{get_group}->();
        $mt5_event_mock{convert_currency}->();
        $bom_rule_engine_mock{new}->();
        $bom_user_client_mock{validate_payment}->();
        $bom_rule_engine_mock{apply_rules}->();
        $bom_user_client_mock{status}->();
        $mt5_mock{get_open_positions_count}->();
        $mt5_mock{get_open_orders_count}->();
        $mt5_mock{user_balance_change}->();
        $mt5_event_mock{financialrounding}->();
        $bom_user_client_mock{payment_mt5_transfer}->();
        $bom_user_client_mock{dbic}->();
        $bom_user_client_account_mock{payment_id}->();
        $mt5_event_mock{record_mt5_transfer}->();
        $bom_user_client_mock{db}->();
        $mt5_mock{update_user}->();
        $mt5_mock{user_archive}->();
    };

    subtest 'can call auto rescind process' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_mock{get_user}->(sub { die {error => "ERR_NOTFOUND"} });

        my $result = $action_get->($args);
        ok $result, 'Success MT5 Auto Rescind Result';
    };

    subtest 'mt5 accounts processed from output same as input' => sub {
        my $args = {
            mt5_accounts    => ['MTR1111', 'MTR2222', 'MTR3333'],
            override_status => 0
        };

        $mt5_mock{get_user}->(sub { die {error => "ERR_NOTFOUND"} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{processed_mt5_accounts}, ['MTR1111', 'MTR2222', 'MTR3333'], 'Processed correct list of MT5 Accounts';
    };

    subtest 'user not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_mock{get_user}->(sub { die {error => "ERR_NOTFOUND"} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'ERR_NOTFOUND'}}, 'Got user not found error';
    };

    subtest 'MT5 Account retrieved without email' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        my %missing_email_mt5_user = %$sample_mt5_user;
        delete $missing_email_mt5_user{email};
        $mt5_mock{get_user}->(sub { Future->done(\%missing_email_mt5_user) });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'MT5 Account retrieved without email'}},
            'Got mt5 account retrieved without email error';
    };

    subtest 'BOM User Account not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_mock{get_user}->();
        $bom_user_mock{new}->(sub { undef; });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'BOM User Account not found'}}, 'Got bom user account not found error';
    };

    subtest 'BOM User Real Loginids not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_mock{get_user}->();
        $bom_user_mock{new}->();
        $bom_user_mock{bom_real_loginids}->(sub { () });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'BOM User Real Loginids not found'}},
            'Got bom user real loginids not found error';
    };

    subtest 'Demo Account detected' => sub {
        my $args = {
            mt5_accounts    => ['MTD10000'],
            override_status => 0
        };

        my %demo_mt5_user = %$sample_mt5_user;
        $demo_mt5_user{group} = 'demo\\p01_ts03\\synthetic\\svg_std_usd\\03';
        $mt5_mock{get_user}->(sub { Future->done(\%demo_mt5_user) });
        $bom_user_mock{new}->();
        $bom_user_mock{bom_real_loginids}->(sub { ('CR90000') });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTD10000' => {'MT5 Error' => 'Demo Account detected, do nothing'}},
            'Got demo account detected, do nothing error';
    };

    subtest 'Error getting Deriv Account' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $bom_user_client_mock{new}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Error getting Deriv Account'}}, 'Got error getting deriv account error';
    };

    subtest 'Deriv Account not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $bom_user_client_mock{new}->(sub { undef; });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Deriv Account not found'}}, 'Got deriv account not found error';
    };

    subtest 'Deriv Account currency not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $bom_user_client_mock{currency}->(sub { undef; });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Deriv Account currency not found'}},
            'Got deriv account currency not found error';
    };

    subtest 'Currency Group not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $mt5_mock{get_group}->(sub { Future->done(undef) });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'Currency Group not found'}}, 'Got currency group not found error';
    };

    subtest 'Validate Payment failed' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $bom_user_client_mock{validate_payment}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Validate Payment failed'}}, 'Got validate payment failed error';
    };

    subtest 'Currency not allowed' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $bom_rule_engine_mock{apply_rules}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Currency not allowed'}}, 'Got currency not allowed error';
    };

    subtest 'Account Disabled error' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $bom_user_client_mock{status}->(sub { bless {disabled => 1}, 'BOM::User::Client::Status' });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Account Disabled'}}, 'Got account disabled error';
    };

    subtest 'MT5 open position error' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $mt5_mock{get_open_positions_count}->(sub { Future->done({total => 2}) });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'Detected 2 open position'}}, 'Got mt5 open position error';
    };

    subtest 'MT5 open order error' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $mt5_mock{get_open_orders_count}->(sub { Future->done({total => 3}) });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'Detected 3 open order'}}, 'Got mt5 open order error';
    };

    subtest 'Balance update failed' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(sub { die {error => "Generic Error"} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case},
            {'MTR10000' => {'MT5 Error' => 'Balance update response failed but may have been updated. Manual check required.'}},
            'Got balance update failed error';
    };

    subtest 'Funds transfer operation completed but error in recording mt5_transfer, archive process skipped' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_user_with_balance{ct}      = 3;
        $mt5_mock{get_user}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{ct}--;
                $mt5_ref->{balance} = '0.00' if $mt5_ref->{ct} == 0;
                return Future->done($mt5_ref);
            });
        $mt5_event_mock{record_mt5_transfer}->(sub { 0 });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case},
            {'MTR10000' => {'CR90000' => 'Funds transfer operation completed but error in recording mt5_transfer, archive process skipped'}},
            'Got mt5 db record error';
    };

    subtest 'Payment MT5 Transfer failed - MT5 Balance changes reverted' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_user_with_balance{ct}      = 3;
        $mt5_mock{get_user}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{ct}--;
                $mt5_ref->{balance} = '0.00' if $mt5_ref->{ct} == 0;
                return Future->done($mt5_ref);
            });
        $bom_user_client_mock{payment_mt5_transfer}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR90000' => 'Payment MT5 Transfer failed - MT5 Balance changes reverted'}},
            'Got payment error';
    };

    subtest 'Payment MT5 Transfer failed - MT5 Balance modified and failed to revert' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_user_with_balance{ct}      = 3;
        $mt5_mock{get_user}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{ct}--;
                $mt5_ref->{balance} = '0.00' if $mt5_ref->{ct} == 0;
                return Future->done($mt5_ref);
            });
        my $balance_change_counter = 2;
        $mt5_mock{user_balance_change}->(
            sub {
                my $ct = \$balance_change_counter;
                $$ct--;
                return Future->done($$ct <= 0 ? {status => 0} : {status => 1});
            });
        $bom_user_client_mock{payment_mt5_transfer}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case},
            {'MTR10000' => {'CR90000' => 'Payment MT5 Transfer failed - MT5 Balance modified and may failed to revert. Manual check required.'}},
            'Got payment with failed to revert error';
    };

    subtest 'Archive condition not met' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                Future->done({status => 0});
            });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'Archive condition not met. Remaining Balance: USD 10.00'}},
            'Got archive condition not met error';
    };

    subtest 'Archive process failed' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $mt5_mock{update_user}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'MT5 Error' => 'Archive process failed'}}, 'Got archive process failed error';
    };

    subtest 'Success Case with Balance 0' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case},
            {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user]}
            },
            'Success Case with Balance 0';
    };

    subtest 'Success Case with Balance 10 from MT5 USD to Deriv USD' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0.0';
                return Future->done({status => 1});
            });

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case}, {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR90000",
                    transferred_deriv_amount   => "10.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR90000"],
            }
            },
            'Success Case with Balance 10 USD to USD';
    };

    subtest 'Success Case with Balance 10 from MT5 USD to Deriv EUR' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0.0';
                return Future->done({status => 1});
            });
        $bom_user_client_mock{currency}->(sub { 'EUR' });

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case}, {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR90000",
                    transferred_deriv_amount   => "9.8",
                    transferred_deriv_currency => "EUR",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR90000"],
            }
            },
            'Success Case with Balance 10 USD to EUR';
    };

    subtest 'Success Case with Balance 10 from MT5 USD to Deriv USD with override_status on Disabled Account' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 1
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0.0';
                return Future->done({status => 1});
            });
        $bom_user_client_mock{status}->(sub { bless {disabled => 1}, 'BOM::User::Client::Status' });

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case}, {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR90000",
                    transferred_deriv_amount   => "10.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR90000"],
            }
            },
            'Success Case with Balance 10 USD to USD with Disabled Account';
    };

    subtest 'Success Case with Balance 10 from MT5 USD to Deriv USD, Customer Transfer of USD 5 with Skip Archive' => sub {
        my $args = {
            mt5_accounts           => ['MTR10000'],
            override_status        => 0,
            custom_transfer_amount => "5.00",
            skip_archive           => 1,
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '5.00';
                return Future->done({status => 1});
            });

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case}, {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [\%mt5_user_with_balance],
                MTR10000     => {
                    transferred_deriv          => "CR90000",
                    transferred_deriv_amount   => "5.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "5.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR90000"],
            }
            },
            'Success Case with Balance 10 and transfer 5 USD to USD';
    };

    subtest 'Success Case with Balance 5 from MT5 USD to Deriv USD, Customer Transfer of USD 5 without Skip Archive' => sub {
        my $args = {
            mt5_accounts           => ['MTR10000'],
            override_status        => 0,
            custom_transfer_amount => "5.00",
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '5.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0';
                return Future->done({status => 1});
            });

        my $result = $action_get->($args)->get;
        is_deeply $result->{success_case}, {
            $auto_rescind_test_client->email => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [\%mt5_user_with_balance],
                MTR10000     => {
                    transferred_deriv          => "CR90000",
                    transferred_deriv_amount   => "5.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "5.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR90000"],
            }
            },
            'Success Case with Balance 5 and transfer 5 USD to USD';
    };

    subtest 'Report Sent for Success Case' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };
        mailbox_clear();

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0.0';
                return Future->done({status => 1});
            });

        my $result = $action_get->($args)->get;
        my $email  = mailbox_search(
            email   => 'i-payments-notification@deriv.com',
            subject => qr/MT5 Account Rescind Report/
        );

        my $expected_email = '<h1>MT5 Auto Rescind Report</h1><br>
        <b>MT5 Processed: </b>
        MTR10000
        <br>
        <br><b>###SUCCESS CASE###</b><br>
        <b>Auto Rescind Successful for: </b>
        MTR10000
        <br>
        <b>Success Result Details:</b><br>
        <b>-</b> MTR10000 (Archived) Transferred USD 10.00 to CR90000 With Value of USD 10.00 <br>
        <br>
        <br>Total MT5 Accounts Processed: 1<br>
        Total MT5 Accounts Processed (Succeed): 1<br>
        Total MT5 Accounts Processed (Failed): 0<br>
        <br><b>###END OF REPORT###</b><br>';

        ok $email, 'MT5 Account Rescind Report sent';
        my @correct_email  = split(' ', $expected_email);
        my @received_email = split(' ', $email->{body});
        is_deeply(\@received_email, \@correct_email, 'correct content');
    };

    subtest 'Report Sent for Success Case with Skip Archive' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0,
            skip_archive    => 1
        };
        mailbox_clear();

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %mt5_user_with_balance = %$sample_mt5_user;
        $mt5_user_with_balance{balance} = '10.00';
        $mt5_mock{get_user}->(sub { Future->done(\%mt5_user_with_balance) });
        $mt5_mock{user_balance_change}->(
            sub {
                my $mt5_ref = \%mt5_user_with_balance;
                $mt5_ref->{balance} = '0.0';
                return Future->done({status => 1});
            });

        my $result = $action_get->($args)->get;
        my $email  = mailbox_search(
            email   => 'i-payments-notification@deriv.com',
            subject => qr/MT5 Account Rescind Report/
        );

        my $expected_email = '<h1>MT5 Auto Rescind Report</h1><br>
        <b>MT5 Processed: </b>
        MTR10000
        <br>
        <br><b>###SUCCESS CASE###</b><br>
        <b>Auto Rescind Successful for: </b>
        MTR10000
        <br>
        <b>Success Result Details:</b><br>
        <b>-</b> MTR10000 (Archive Skipped) Transferred USD 10.00 to CR90000 With Value of USD 10.00 <br>
        <br>
        <br>Total MT5 Accounts Processed: 1<br>
        Total MT5 Accounts Processed (Succeed): 1<br>
        Total MT5 Accounts Processed (Failed): 0<br>
        <br><b>###END OF REPORT###</b><br>';

        ok $email, 'MT5 Account Rescind Report sent';
        my @correct_email  = split(' ', $expected_email);
        my @received_email = split(' ', $email->{body});
        is_deeply(\@received_email, \@correct_email, 'correct content');
    };

    subtest 'Report Sent for Failed Case' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };
        mailbox_clear();

        $mt5_mock{get_user}->(sub { die {error => "ERR_NOTFOUND"} });

        my $result = $action_get->($args)->get;
        my $email  = mailbox_search(
            email   => 'i-payments-notification@deriv.com',
            subject => qr/MT5 Account Rescind Report/
        );

        my $expected_email = '<h1>MT5 Auto Rescind Report</h1><br>
        <b>MT5 Processed: </b>
        MTR10000
        <br>
        <br><b>###FAILED CASE###</b><br>
        <b>Auto Rescind Failed for: </b>
        MTR10000
        <br>
        <b>Failed Result Details:</b><br>
        <b>-</b> MTR10000<br>
        &nbsp&nbsp* MT5 Error : ERR_NOTFOUND <br>
        <br>Total MT5 Accounts Processed: 1<br>
        Total MT5 Accounts Processed (Succeed): 0<br>
        Total MT5 Accounts Processed (Failed): 1<br>
        <br><b>###END OF REPORT###</b><br>';

        ok $email, 'MT5 Account Rescind Report sent';
        my @correct_email  = split(' ', $expected_email);
        my @received_email = split(' ', $email->{body});
        is_deeply(\@received_email, \@correct_email, 'correct content');
    };

    subtest 'Report Sent for Success and Failed Case' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000', 'MTR20000'],
            override_status => 0
        };
        mailbox_clear();

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        my %alt_sample_mt5_user = %$sample_mt5_user;
        $alt_sample_mt5_user{login} = 'MTR20000';

        $mt5_mock{get_user}->(
            sub {
                my $mt5_id = shift;
                return Future->done($sample_mt5_user)      if $mt5_id eq 'MTR10000';
                return Future->done(\%alt_sample_mt5_user) if $mt5_id eq 'MTR20000';
            });

        $mt5_mock{get_open_positions_count}->(
            sub {
                my $mt5_id = shift;
                return Future->done({total => 2}) if $mt5_id eq 'MTR10000';
                return Future->done({total => 0}) if $mt5_id eq 'MTR20000';
            });

        my $result = $action_get->($args)->get;
        my $email  = mailbox_search(
            email   => 'i-payments-notification@deriv.com',
            subject => qr/MT5 Account Rescind Report/
        );

        my $expected_email = '<h1>MT5 Auto Rescind Report</h1><br>
        <b>MT5 Processed: </b>
        MTR10000, MTR20000
        <br>
        <br><b>###SUCCESS CASE###</b><br>
        <b>Auto Rescind Successful for: </b>
        MTR20000
        <br>
        <b>Success Result Details:</b><br>
        <b>-</b> MTR20000 (Archived) No Transfer<br>
        <br>
        <br><b>###FAILED CASE###</b><br>
        <b>Auto Rescind Failed for: </b>
        MTR10000
        <br>
        <b>Failed Result Details:</b><br>
        <b>-</b> MTR10000<br>
        &nbsp&nbsp* MT5 Error : Detected 2 open position <br>
        <br>Total MT5 Accounts Processed: 2<br>
        Total MT5 Accounts Processed (Succeed): 1<br>
        Total MT5 Accounts Processed (Failed): 1<br>
        <br><b>###END OF REPORT###</b><br>';

        ok $email, 'MT5 Account Rescind Report sent';
        my @correct_email  = split(' ', $expected_email);
        my @received_email = split(' ', $email->{body});
        is_deeply(\@received_email, \@correct_email, 'correct content');
    };
};

subtest 'link myaffiliate token to mt5' => sub {

    # MyAffiliate connection error test

    my $args;
    my $process_result;

    my $mocked_actions      = Test::MockModule->new('BOM::Event::Actions::MT5');
    my $mocked_myaffiliates = Test::MockModule->new('WebService::MyAffiliates');

    $mocked_actions->mock(
        'link_myaff_token_to_mt5',
        sub {
            $args = shift;
            return $mocked_actions->original('link_myaff_token_to_mt5')->($args);
        });

    $mocked_actions->mock(
        '_get_ib_affiliate_id_from_token',
        sub {
            die "Unable to connect to MyAffiliate to parse token";
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {}});

    like($process_result->{failure}[0], qr/Unable to connect to MyAffiliate to parse token/, "Correct expected error message");
    $mocked_actions->unmock_all();

    # Faulty token error test

    $mocked_actions->mock(
        'link_myaff_token_to_mt5',
        sub {
            $args = shift;
            return $mocked_actions->original('link_myaff_token_to_mt5')->($args);
        });

    $mocked_myaffiliates->mock(
        'get_affiliate_id_from_token',
        sub {
            $args = shift;
            return 123;
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {
                myaffiliates_token => 'dummy_token',
            }});

    like($process_result->{failure}[0], qr/Unable to get MyAffiliate user 123 from token dummy_token/, "Correct expected error message");

    $mocked_myaffiliates->unmock_all();

    # Token mapping error test

    $mocked_myaffiliates->mock(
        'get_affiliate_id_from_token',
        sub {
            $args = shift;
            return "Not a token";
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {
                myaffiliates_token => 'dummy_token',
            }});

    like($process_result->{failure}[0], qr/Unable to map token dummy_token to an affiliate/, "Correct expected error message");

    $mocked_myaffiliates->unmock_all();

    # User variable error test

    $mocked_actions->mock(
        '_get_mt5_agent_account_id',
        sub {
            $args = shift;
            return 123;
        });

    $mocked_myaffiliates->mock(
        'get_affiliate_id_from_token',
        sub {
            $args = shift;
            return 123;
        });

    $mocked_myaffiliates->mock(
        'get_user',
        sub {
            $args = shift;
            my $user->{USER_VARIABLES}{VARIABLE} = "Not a user";
            return $user;
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {
                myaffiliates_token => 'dummy_token',
            }});

    like($process_result->{failure}[0], qr/User variable is not defined for 123 from token dummy_token/, "Correct expected error message");

    $mocked_myaffiliates->unmock_all();
    $mocked_actions->unmock_all();

    # Linking success test

    $mocked_actions->mock(
        'link_myaff_token_to_mt5',
        sub {
            $args = shift;
            return $mocked_actions->original('link_myaff_token_to_mt5')->($args);
        });

    $mocked_actions->mock(
        '_get_mt5_agent_account_id',
        sub {
            $args = shift;
            return 123;
        });

    $mocked_myaffiliates->mock(
        'get_affiliate_id_from_token',
        sub {
            $args = shift;
            return 123;
        });

    $mocked_mt5->mock(
        'get_user',
        sub {
            return Future->done({"result" => "ok"});
        });

    $mocked_mt5->mock(
        'update_user',
        sub {
            return Future->done({"result" => "ok"});
        });

    $mocked_myaffiliates->mock(
        'get_user',
        sub {
            $args = shift;
            my $user = {
                'USER_VARIABLES' => {
                    'VARIABLE' => [{
                            NAME  => "mt5_account",
                            VALUE => 1234
                        }]}};

            return $user;
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {
                client_loginid     => 'dummy',
                client_mt5_login   => 'MTR123456',
                broker_code        => 'dummy',
                myaffiliates_token => 'dummy_token',
            }});

    like($process_result->{result}[0], qr/Successfully linked client MTR123456 to affiliate 123/, "The success message is returned correctly");

    $mocked_myaffiliates->unmock_all();
    $mocked_actions->unmock_all();
    $mocked_mt5->unmock_all();

    # User not found test
    $mocked_actions->mock(
        'link_myaff_token_to_mt5',
        sub {
            $args = shift;
            return $mocked_actions->original('link_myaff_token_to_mt5')->($args);
        });

    $mocked_actions->mock(
        '_get_ib_affiliate_id_from_token',
        sub {
            $args = shift;
            return 123;
        });

    $mocked_actions->mock(
        '_get_mt5_agent_account_id',
        sub {
            $args = shift;
            return 'MTR123';
        });

    $mocked_mt5->mock(
        'get_user',
        sub {
            $args = shift;
            my $error->{error} = "Not found";
            die $error;
        });

    $process_result = BOM::Event::Process->new(category => 'mt5_retryable')->process({
            type    => 'link_myaff_token_to_mt5',
            details => {
                client_mt5_login => 'MTR123456',
            }});

    $log->contains_ok(qr/An error occured while retrieving user 'MTR123456' from MT5 : \{error => \"Not found\"\}/, "Correct expected error message");
    is($process_result->{result}[0], 1, "Correct returned value");
};

subtest 'sync mt5 accounts status' => sub {
    my $req = BOM::Platform::Context::Request->new(
        brand_name => 'deriv',
        language   => 'id',
        app_id     => $app_id,
    );
    request($req);

    $mocked_user->unmock_all;
    $mocked_user_client->unmock_all;
    $mocked_rule_engine->unmock_all;

    my $sample_bom_user = {
        email              => 'testsyncstatus@test.com',
        preferred_language => 'en'
    };

    my $sample_bom_user_client = {
        loginid  => 'CR900000',
        currency => 'USD',
    };

    my $sample_loginid_details = {
        CR10002 => {
            account_type   => undef,
            attributes     => {},
            creation_stamp => "2017-09-14 07:13:52.727067",
            currency       => undef,
            loginid        => "CR10002",
            platform       => undef,
            status         => undef,
        },
    };

    my $sample_bvi_mt5 = {
        MTR1001017 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\bvi_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-14 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001017",
            platform       => "mt5",
            status         => 'poa_pending',
        },
    };

    my $sample_bvi_mt5_active = {
        MTR1001018 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\bvi_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-14 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001018",
            platform       => "mt5",
            status         => undef,
        },
    };

    my $sample_vanuatu_mt5 = {
        MTR1001020 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\vanuatu_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-14 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001020",
            platform       => "mt5",
            status         => 'poa_pending',
        },
    };

    my $sample_labuan_mt5 = {
        MTR1001030 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\labuan_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-14 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001030",
            platform       => "mt5",
            status         => 'poa_pending',
        },
    };

    my $sample_maltainvest_mt5 = {
        MTR1001040 => {
            account_type => "real",
            attributes   => {
                account_type    => "real",
                currency        => "USD",
                group           => "real\\p01_ts01\\financial\\maltainvest_std_usd",
                landing_company => "svg",
                leverage        => 300,
                market_type     => "financial",
            },
            creation_stamp => "2018-02-14 07:13:52.94334",
            currency       => "USD",
            loginid        => "MTR1001040",
            platform       => "mt5",
            status         => 'poa_pending',
        },
    };

    set_absolute_time(Date::Utility->new('2018-02-15')->epoch);
    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{sync_mt5_accounts_status};
    my $action_get     = sub { $action_handler->(shift)->get->get };

    my %bom_user_mock = (
        new => sub {
            $mocked_user->mock('new', shift // sub { bless $sample_bom_user, 'BOM::User' });
        },
        get_default_client => sub {
            $mocked_user->mock('get_default_client', shift // sub { bless $sample_bom_user_client, 'BOM::User::Client' });
        },
        loginid_details => sub {
            $mocked_user->mock('loginid_details', shift // sub { $sample_loginid_details });
        },
        update_loginid_status => sub {
            $mocked_user->mock('update_loginid_status', shift // sub { 1 });
        });

    my %bom_user_client_mock = (
        new => sub {
            $mocked_user_client->mock('new', shift // sub { bless $sample_bom_user_client, 'BOM::User::Client' });
        },
        user => sub {
            $mocked_user_client->mock('user', shift // sub { bless $sample_bom_user, 'BOM::User' });
        },
        get_poi_status => sub {
            $mocked_user_client->mock('get_poi_status_jurisdiction', shift // sub { return 'verified'; });
        },
        get_poa_status => sub {
            $mocked_user_client->mock('get_poa_status', shift // sub { return 'verified'; });
        });

    my $sync_mt5_mock_set = sub {
        $bom_user_mock{new}->();
        $bom_user_mock{get_default_client}->();
        $bom_user_mock{loginid_details}->();
        $bom_user_mock{update_loginid_status}->();
        $bom_user_client_mock{new}->();
        $bom_user_client_mock{user}->();
        $bom_user_client_mock{get_poi_status}->();
        $bom_user_client_mock{get_poa_status}->();
    };

    # BVI SERIES
    subtest 'BVI Account Test' => sub {
        subtest 'BVI Account POI Verified Subcases' => sub {
            subtest 'BVI Account - POI and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => undef},          'Updated status is undefined';
            };

            subtest 'BVI Account - POI verified and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'poa_pending'},  'Updated status is poa_pending';
            };

            subtest 'BVI Account - POI verified and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'poa_pending'},  'Updated status is poa_pending';
            };

            subtest 'BVI Account - POI verified and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'poa_failed'},   'Updated status is poa_failed';
            };

            subtest 'BVI Account - POI verified and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'poa_failed'},   'Updated status is poa_failed';
            };
        };

        subtest 'BVI Account POI Pending Subcases' => sub {
            subtest 'BVI Account - POI and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'BVI Account - POI pending and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'BVI Account - POI pending and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'BVI Account - POI pending and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'BVI Account - POI pending and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'verification_pending'}, 'Updated status is verification_pending';
            };
        };

        subtest 'BVI Account POI Rejected Subcases' => sub {
            subtest 'BVI Account - POI and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'BVI Account - POI rejected and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'BVI Account - POI rejected and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_bvi_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'BVI Account - POI rejected and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'BVI Account - POI rejected and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_bvi_mt5 = %$sample_bvi_mt5;
                $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
                $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {bvi => ["MTR1001017"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {bvi => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };

        subtest 'BVI Account - POI verified and POA pending (past grace period) with update to existing active bvi' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %expire_bvi_mt5 = %$sample_bvi_mt5;
            $expire_bvi_mt5{MTR1001017}                   = {%{$sample_bvi_mt5->{MTR1001017}}};
            $expire_bvi_mt5{MTR1001018}                   = {%{$sample_bvi_mt5_active->{MTR1001018}}};
            $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            $expire_bvi_mt5{MTR1001018}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            cmp_deeply $result->{processed_mt5}, {bvi => bag("MTR1001017", "MTR1001018")}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {bvi => 'poa_failed'}, 'Updated status is poa_failed';
        };

        subtest 'BVI Account - POI verified and POA pending (past grace period) with update to only active bvi' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %expire_bvi_mt5 = %$sample_bvi_mt5;
            $expire_bvi_mt5{MTR1001017}                   = {%{$sample_bvi_mt5->{MTR1001017}}};
            $expire_bvi_mt5{MTR1001017}->{status}         = undef;
            $expire_bvi_mt5{MTR1001018}                   = {%{$sample_bvi_mt5_active->{MTR1001018}}};
            $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            $expire_bvi_mt5{MTR1001018}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            cmp_deeply $result->{processed_mt5}, {bvi => bag("MTR1001017", "MTR1001018")}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {bvi => 'poa_failed'}, 'Updated status is poa_failed';
        };

        subtest 'BVI Account - POI verified and POA pending (past grace period) with no update to archived bvi' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %expire_bvi_mt5 = %$sample_bvi_mt5;
            $expire_bvi_mt5{MTR1001017}                   = {%{$sample_bvi_mt5->{MTR1001017}}};
            $expire_bvi_mt5{MTR1001017}->{status}         = 'archived';
            $expire_bvi_mt5{MTR1001018}                   = {%{$sample_bvi_mt5_active->{MTR1001018}}};
            $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            $expire_bvi_mt5{MTR1001018}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            cmp_deeply $result->{processed_mt5}, {bvi => bag("MTR1001018")}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {bvi => 'poa_failed'}, 'Updated status is poa_failed';
        };
    };

    # Vanuatu Series
    subtest 'Vanuatu Account Test' => sub {
        subtest 'Vanuatu Account POI Verified Subcases' => sub {
            subtest 'Vanuatu Account - POI and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => undef},          'Updated status is undefined';
            };

            subtest 'Vanuatu Account - POI verified and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'poa_pending'},  'Updated status is poa_pending';
            };

            subtest 'Vanuatu Account - POI verified and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'poa_pending'},  'Updated status is poa_pending';
            };

            subtest 'Vanuatu Account - POI verified and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'poa_failed'},   'Updated status is poa_failed';
            };

            subtest 'Vanuatu Account - POI verified and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'poa_failed'},   'Updated status is poa_failed';
            };
        };

        subtest 'Vanuatu Account POI Pending Subcases' => sub {
            subtest 'Vanuatu Account - POI and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Vanuatu Account - POI pending and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Vanuatu Account - POI pending and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Vanuatu Account - POI pending and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Vanuatu Account - POI pending and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'verification_pending'}, 'Updated status is verification_pending';
            };
        };

        subtest 'Vanuatu Account POI Rejected Subcases' => sub {
            subtest 'Vanuatu Account - POI and POA rejected (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Vanuatu Account - POI rejected and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Vanuatu Account - POI rejected and POA pending (within grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_vanuatu_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Vanuatu Account - POI rejected and POA pending (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Vanuatu Account - POI rejected and POA rejected (past grace period)' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();

                my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
                $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
                $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
                my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {vanuatu => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };
    };

    # Labuan Series
    subtest 'Labuan Account Test' => sub {
        subtest 'Labuan Account POI Verified Subcases' => sub {
            subtest 'Labuan Account - POI and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => undef},          'Updated status is undefined';
            };

            subtest 'Labuan Account - POI verified and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Labuan Account - POI verified and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };

        subtest 'Labuan Account POI Pending Subcases' => sub {
            subtest 'Labuan Account - POI and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Labuan Account - POI pending and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Labuan Account - POI pending and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };

        subtest 'Labuan Account POI Rejected Subcases' => sub {
            subtest 'Labuan Account - POI and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Labuan Account - POI rejected and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Labuan Account - POI rejected and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_labuan_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {labuan => ["MTR1001030"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {labuan => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };
    };

    # Maltainvest Series
    subtest 'Maltainvest Account Test' => sub {
        subtest 'Maltainvest Account POI Verified Subcases' => sub {
            subtest 'Maltainvest Account - POI and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => undef},          'Updated status is undefined';
            };

            subtest 'Maltainvest Account - POI verified and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Maltainvest Account - POI verified and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };

        subtest 'Maltainvest Account POI Pending Subcases' => sub {
            subtest 'Maltainvest Account - POI and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Maltainvest Account - POI pending and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]},         'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'verification_pending'}, 'Updated status is verification_pending';
            };

            subtest 'Maltainvest Account - POI pending and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'pending' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };

        subtest 'Maltainvest Account POI Rejected Subcases' => sub {
            subtest 'Maltainvest Account - POI and POA rejected' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'rejected' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Maltainvest Account - POI rejected and POA verified' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'proof_failed'}, 'Updated status is proof_failed';
            };

            subtest 'Maltainvest Account - POI rejected and POA pending' => sub {
                my $args = {
                    client_loginid => 1,
                };

                $sync_mt5_mock_set->();
                my $loginid_data = {%$sample_loginid_details, %$sample_maltainvest_mt5};
                $bom_user_mock{loginid_details}->(sub { $loginid_data });
                $bom_user_client_mock{get_poi_status}->(sub { 'rejected' });
                $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

                my $result = $action_get->($args);
                is_deeply $result->{processed_mt5},  {maltainvest => ["MTR1001040"]}, 'Correct mt5 processed';
                is_deeply $result->{updated_status}, {maltainvest => 'proof_failed'}, 'Updated status is proof_failed';
            };
        };
    };

    subtest 'Mixed Account Test' => sub {
        subtest 'BVI (past grace period) and Vanuatu (within grace period)' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %second_bvi_mt5 = (MTR1001018 => {%{$sample_bvi_mt5->{MTR1001017}}});
            my %expire_bvi_mt5 = %$sample_bvi_mt5;
            $expire_bvi_mt5{MTR1001017} = {%{$sample_bvi_mt5->{MTR1001017}}};
            $expire_bvi_mt5{MTR1001017}->{creation_stamp} = "2018-02-4 07:13:52.94334";
            my $loginid_data = {%$sample_loginid_details, %expire_bvi_mt5, %second_bvi_mt5, %$sample_vanuatu_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            cmp_deeply $result->{processed_mt5},
                {
                bvi     => bag("MTR1001017", "MTR1001018"),
                vanuatu => ["MTR1001020"]
                },
                'Correct mt5 processed';
            is_deeply $result->{updated_status},
                {
                bvi     => 'poa_failed',
                vanuatu => 'poa_pending'
                },
                'Updated status is bvi-poa_failed and vanuatu-poa_pending';
        };

        subtest 'BVI (within grace period) and Vanuatu (within grace period)' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %second_bvi_mt5 = (MTR1001018 => {%{$sample_bvi_mt5->{MTR1001017}}});
            my $loginid_data   = {%$sample_loginid_details, %$sample_bvi_mt5, %second_bvi_mt5, %$sample_vanuatu_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            cmp_deeply $result->{processed_mt5},
                {
                bvi     => bag("MTR1001017", "MTR1001018"),
                vanuatu => ["MTR1001020"]
                },
                'Correct mt5 processed';
            is_deeply $result->{updated_status},
                {
                bvi     => 'poa_pending',
                vanuatu => 'poa_pending'
                },
                'Updated status is poa_pending for both';
        };

        subtest 'No MT5 accounts' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my $loginid_data = {%$sample_loginid_details};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            is_deeply $result->{processed_mt5},  {}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {}, 'Nothing is updated';
        };

    };

    subtest 'Color Update Test' => sub {
        subtest 'POA failed update color to 255' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
            $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
            $expire_vanuatu_mt5{MTR1001020}->{creation_stamp} = "2018-02-9 07:13:52.94334";
            my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'pending' });

            my $result = $action_get->($args);
            is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {vanuatu => 'poa_failed'},   'Updated status is poa_failed';
            is_deeply $result->{updated_color},  {vanuatu => 255},            'Updated color to red';
        };

        subtest 'POA failed is verified update color to -1' => sub {
            my $args = {
                client_loginid => 1,
            };

            $sync_mt5_mock_set->();

            my %expire_vanuatu_mt5 = %$sample_vanuatu_mt5;
            $expire_vanuatu_mt5{MTR1001020} = {%{$sample_vanuatu_mt5->{MTR1001020}}};
            $expire_vanuatu_mt5{MTR1001020}->{status} = "poa_failed";
            my $loginid_data = {%$sample_loginid_details, %expire_vanuatu_mt5};

            $bom_user_mock{loginid_details}->(sub { $loginid_data });
            $bom_user_client_mock{get_poi_status}->(sub { 'verified' });
            $bom_user_client_mock{get_poa_status}->(sub { 'verified' });

            my $result = $action_get->($args);
            is_deeply $result->{processed_mt5},  {vanuatu => ["MTR1001020"]}, 'Correct mt5 processed';
            is_deeply $result->{updated_status}, {vanuatu => undef},          'Updated status is poa_failed';
            is_deeply $result->{updated_color},  {vanuatu => -1},             'Updated color to none';
        };
    };

    $mocked_user->unmock_all;
    $mocked_user_client->unmock_all;
    $mocked_rule_engine->unmock_all;
};

subtest 'mt5 archive restore sync' => sub {
    my $args = {};

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{mt5_archive_restore_sync};

    like exception { $action_handler->($args)->get; }, qr/Must provide list of MT5 loginids/, 'correct exception when MT5 id list is missing';

    $args->{mt5_accounts} = ['MTR90000'];

    $mocked_mt5->mock('get_user', sub { Future->done({login => "MTR90000", email => 'placeholder@gmail.com'}) });
    $mocked_user->mock('new',              sub { bless {}, 'BOM::User' });
    $mocked_user->mock('get_mt5_loginids', ('MTR90000'));

    my $result = $action_handler->($args)->get;
    ok $result, 'Success mt5 archive restore sync result';

    $mocked_mt5->unmock_all;
    $mocked_user->unmock_all;
};

subtest 'sync_mt5_accounts_status' => sub {
    my $user = BOM::User->create(
        email          => 'sync_mt5_accounts_status@binary.com',
        password       => 'supahsus',
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'sync_mt5_accounts_status@binary.com',
    });

    my $args = {};

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{sync_mt5_accounts_status};

    like exception { $action_handler->($args)->get; }, qr/Must provide client_loginid/, 'correct exception when user has no client id provided';

    $args->{client_loginid} = 'CR101';
    $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{sync_mt5_accounts_status};

    like exception { $action_handler->($args)->get; }, qr/Client not found/, 'correct exception when invalid client id provided';

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->user($user);
    $client->save;
    my $original_details = $user->loginid_details;

    $args->{client_loginid} = $client->loginid;

    my $result = $action_handler->($args)->get->get;    # async sub returns explicit Future->done !!

    cmp_deeply $result,
        {
        processed_mt5  => {},
        updated_status => {},
        updated_color  => {}
        },
        'nothing to process';

    my $user_mock      = Test::MockModule->new('BOM::User');
    my $extra_loginids = {};

    $user_mock->mock(
        'loginid_details',
        sub {
            my %extra = map { $_ => {$extra_loginids->{$_}->%*, loginid => $_, is_external => 1} } keys %$extra_loginids;
            return {%extra, %$original_details};
        });

    # mt5 demo is skipped
    # non mt5 is also skipped

    $extra_loginids = {
        MTD000001 => {
            platform     => 'mt5',
            account_type => 'demo'
        },
        DXR1000001 => {
            account_type => 'real',
            platform     => 'dxtrade'
        },
    };

    $result = $action_handler->($args)->get->get;

    cmp_deeply $result,
        {
        processed_mt5  => {},
        updated_status => {},
        updated_color  => {}
        },
        'nothing to process';

    # mt5 real would get skipped if no group
    # mt55 real would get skipped if the group is not bvi|vanuatu|labuan|maltainvest
    # mt5 real would get skipped if status not in 'poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated'

    $extra_loginids = {
        MTD000001 => {
            platform     => 'mt5',
            account_type => 'demo'
        },
        DXR1000001 => {
            account_type => 'real',
            platform     => 'dxtrade'
        },
        MTR000001 => {
            platform     => 'mt5',
            account_type => 'real',
            attributes   => {
                group => undef,
            }
        },
        MTR000002 => {
            platform     => 'mt5',
            account_type => 'real',
            attributes   => {group => 'sus'}
        },
        MTR000003 => {
            platform     => 'mt5',
            account_type => 'real',
            attributes   => {group => 'maltainvest'},
            status       => undef,
        },
        MTR000004 => {
            platform     => 'mt5',
            account_type => 'real',
            attributes   => {group => 'maltainvest'},
            status       => 'sus',
        },
    };

    $result = $action_handler->($args)->get->get;

    cmp_deeply $result,
        {
        processed_mt5 => {
            maltainvest => [qw/MTR000003/],
        },
        updated_status => {
            maltainvest => 'proof_failed',
        },
        updated_color => {}
        },
        'processing undef status';

    ## mock the update status fn
    my $status_updates = {};

    $user_mock->mock(
        'update_loginid_status',
        sub {
            my (undef, $mt5_id, $status) = @_;

            $status_updates->{$mt5_id} = $status;
        });

    ## mock the event emitter

    my $emitter_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $emissions    = [];

    $emitter_mock->mock(
        'emit',
        sub {
            push $emissions->@*, {@_};
        });

    ## mock the rule engine to throw with undef proof_failed_with_status

    my $rule_engine_mock = Test::MockModule->new('BOM::Rules::Engine');
    my $mt5_status;
    my $rule_fail;

    $rule_engine_mock->mock(
        'verify_action',
        sub {
            if ($rule_fail) {
                die +{
                    params => {
                        mt5_status => $mt5_status,
                    }};
            }

            return 1;
        });

    $rule_fail  = 1;
    $mt5_status = undef;

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            $emissions      = [];
            $status_updates = {};
            $log->clear;

            $extra_loginids = {
                MTR000005 => {
                    platform     => 'mt5',
                    account_type => 'real',
                    attributes   => {
                        group => $jurisdiction,
                    },
                    status => $status,
                },
            };

            $result = $action_handler->($args)->get->get;

            my $str_status = $status // 'undef';

            cmp_deeply $result,
                {
                processed_mt5 => {
                    $jurisdiction => ['MTR000005'],
                },
                updated_status => {},
                updated_color  => {}
                },
                "expected results $jurisdiction $str_status (undef mt5_status thrown)";

            cmp_deeply $status_updates, {}, 'no status changed';
            cmp_deeply $emissions, [], 'Empty emissions';

            cmp_deeply $log->msgs,
                [{
                    message  => 'Unexpected behavior. MT5 accounts sync rule failed without mt5 status',
                    level    => 'warning',
                    category => 'BOM::Event::Actions::MT5'
                }
                ],
                'Expected warnings';
        }
    }

    ## test the statuses across jurisdictions
    ## expected result = proof_failed
    ## no color swap expected

    $rule_fail  = 1;
    $mt5_status = 'proof_failed';

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            $emissions      = [];
            $status_updates = {};
            $log->clear;

            $extra_loginids = {
                MTR000005 => {
                    platform     => 'mt5',
                    account_type => 'real',
                    attributes   => {
                        group => $jurisdiction,
                    },
                    status => $status,
                },
            };

            my $str_status = $status // 'undef';

            $result = $action_handler->($args)->get->get;

            cmp_deeply $result,
                {
                processed_mt5 => {
                    $jurisdiction => ['MTR000005'],
                },
                updated_status => {
                    $jurisdiction => 'proof_failed',
                },
                updated_color => {}
                },
                "expected results $jurisdiction $str_status => proof_failed";

            cmp_deeply $emissions,                                     [], 'Empty emissions';
            cmp_deeply $status_updates, {MTR000005 => 'proof_failed'}, 'status changed';
            cmp_deeply $log->msgs,                                     [], 'No warnings';
        }
    }

    ## test the statuses across jurisdictions
    ## expected result = poa_failed
    ## color swap to COLOR_RED expected

    $rule_fail  = 1;
    $mt5_status = 'poa_failed';

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            $emissions      = [];
            $status_updates = {};
            $log->clear;

            $extra_loginids = {
                MTR000005 => {
                    platform     => 'mt5',
                    account_type => 'real',
                    attributes   => {
                        group => $jurisdiction,
                    },
                    status => $status,
                },
            };

            my $str_status = $status // 'undef';

            $result = $action_handler->($args)->get->get;

            cmp_deeply $result,
                {
                processed_mt5 => {
                    $jurisdiction => ['MTR000005'],
                },
                updated_status => {
                    $jurisdiction => 'poa_failed',
                },
                updated_color => {
                    $jurisdiction => +BOM::Event::Actions::MT5::COLOR_RED,
                }
                },
                "expected results $jurisdiction $str_status => poa_failed";

            cmp_deeply $emissions,
                [{
                    mt5_change_color => {
                        loginid => 'MTR000005',
                        color   => +BOM::Event::Actions::MT5::COLOR_RED,
                    }}
                ],
                'Expected change color emission';

            cmp_deeply $status_updates, {MTR000005 => 'poa_failed'}, 'status changed';
            cmp_deeply $log->msgs, [], 'No warnings';
        }
    }

    ## test the statuses across jurisdictions
    ## expected result = undef status
    ## color swap to COLOR_NONE expected if current status is poa_failed

    $rule_fail  = 0;
    $mt5_status = undef;

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            $emissions      = [];
            $status_updates = {};
            $log->clear;

            $extra_loginids = {
                MTR000005 => {
                    platform     => 'mt5',
                    account_type => 'real',
                    attributes   => {
                        group => $jurisdiction,
                    },
                    status => $status,
                },
            };

            my $str_status = $status // 'undef';

            $result = $action_handler->($args)->get->get;

            cmp_deeply $result,
                {
                processed_mt5 => {
                    $jurisdiction => ['MTR000005'],
                },
                updated_status => {
                    $jurisdiction => undef,
                },
                updated_color => {$str_status eq 'poa_failed' ? ($jurisdiction => +BOM::Event::Actions::MT5::COLOR_NONE) : (),}
                },
                "expected results $jurisdiction $str_status => undef";

            cmp_deeply $emissions,
                [
                $str_status eq 'poa_failed'
                ? {
                    mt5_change_color => {
                        loginid => 'MTR000005',
                        color   => +BOM::Event::Actions::MT5::COLOR_NONE,
                    }}
                : ()
                ],
                'Expected change color emission';

            cmp_deeply $status_updates, {MTR000005 => undef}, 'status changed';
            cmp_deeply $log->msgs, [], 'No warnings';
        }
    }
    $rule_engine_mock->unmock_all;
    $user_mock->unmock_all;
};

# Testing the mt5_deposit_retry function
subtest 'mt5_deposit_retry function' => sub {
    # Mock current time
    set_fixed_time('2023-05-24T15:00:00Z');

    # Mock necessary modules
    my $mocked_actions = Test::MockModule->new('BOM::User::Client::Account');
    my $mock_mt5       = Test::MockModule->new('BOM::MT5::User::Async');

    # Mock 'find_transaction' method in BOM::User::Client::Account
    $mocked_actions->mock(
        'find_transaction',
        sub {
            my ($self, %args) = @_;
            # Returns true for id '539', false otherwise
            return ($args{query}[1] eq '539') ? 1 : 0;
        });

    # Create client object with pre-existing account
    my $client = BOM::User::Client->new({loginid => 'CR10000'});

    # Create account object for client
    $client->account('USD');

    # Define test parameters
    my $parameters = {
        from_login_id           => 'CR10000',
        destination_mt5_account => 'MTR40008267',
        amount                  => 12,
        mt5_comment             => 'MTR40008267#123456',
        server                  => 'real_p01_ts03',
        transaction_id          => 539,
        datetime_start          => '2023-05-24T14:00:00Z',
    };

    # Mock deal_get_batch response
    my $async_deal_get_batch_response = {
        'deal_get_batch' => [{
                'rateMargin'   => '0.00000000',
                'reason'       => 2,
                'price'        => '0.00',
                'symbol'       => '',
                'order'        => 0,
                'action'       => 2,
                'priceTP'      => '0.00',
                'positionID'   => 0,
                'volume'       => 0,
                'comment'      => 'MTR40008267#539',
                'login'        => 40008267,
                'contractSize' => '0.00',
                'deal'         => 3000010207,
                'time'         => 1668078126,
                'profit'       => '12.00',
                'swap'         => undef,
                'priceSL'      => '0.00'
            }]};
    $mock_mt5->mock('deal_get_batch', sub { return Future->done($async_deal_get_batch_response); });

    # Call mt5_deposit_retry function and test if transaction already exists
    my $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $parameters})->get;
    is($result->get, 'Transaction already exist in mt5', 'Transaction already exists test');

    # Test for a non-existent transaction id
    $parameters->{transaction_id} = 999999;
    $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $parameters});
    like($result->failure, qr/Cannot find transaction id: 999999/, 'Transaction not found test');

    # Test for a demo deposit
    $parameters->{server} = 'demo_p01_ts03';
    $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $parameters});
    like($result->failure, qr/Do not need to try demo deposit/, 'Demo deposit test');

    $log->info("End testing mt5_deposit_retry function");
};

done_testing();
