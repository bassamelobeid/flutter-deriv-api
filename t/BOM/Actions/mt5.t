use strict;
use warnings;

use Test::Deep;
use Test::More;
use Test::Fatal;
use Test::MockTime qw(:all);
use Time::Moment;
use Clone 'clone';
use Future::AsyncAwait;

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
use JSON::MaybeXS      qw(encode_json);
use BOM::Config::Runtime;
use Clone 'clone';
use Deriv::TradingPlatform::MT5::UserRights qw(get_value);

my $brand = Brands->new(name => 'deriv');
my ($app_id) = $brand->whitelist_apps->%*;

my (@identify_args, @track_args, @transactional_args);
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

my $mock_cio = Test::MockModule->new('WebService::Async::CustomerIO');
$mock_cio->redefine(
    'send_transactional' => sub {
        @transactional_args = @_;
        return Future->done(1);
    });

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
my $mocked_mt5_async           = Test::MockModule->new('BOM::MT5::User::Async');

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
                mt5_server_environment => 'DerivSVG-Server-02',
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

    subtest 'mt5 signup track - mt5_signup_derived' => sub {
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);    #activate transactional.
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
        undef @transactional_args;

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

        my $sent_properties = {
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
            mt5_server_environment => 'DerivSVG-Server-02',
            lang                   => 'ID',
            mt5_dashboard_url      => 'https://app.deriv.com/mt5?lang=id',
            live_chat_url          => 'https://deriv.com/id/?is_livechat_open=true'
        };

        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'track_mt5_signup',
            properties => $sent_properties
            },
            'properties are set properly for new mt5 account event';

        is scalar(@identify_args), 0, 'Identify is not triggered';

        my ($transactional_customer, $transactional_args) = @transactional_args;

        is_deeply $transactional_args->{message_data}, $sent_properties, 'Transactional email data is correct';
        is $transactional_args->{transactional_message_id}, 'mt5_signup_derived', 'Transactional email id is correct';

        undef @track_args;

        $args->{mt5_login_id} = '';
        like exception { $action_handler->($args); }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);    #deactivate transactional.
    };

    subtest 'mt5 signup track - mt5_signup_demo' => sub {
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);    #activate transactional.
        my $args = {
            loginid            => $test_client->loginid,
            'account_type'     => 'demo',
            'language'         => 'EN',
            'mt5_group'        => 'demo\\p01_ts03\\financial\\svg_std_usd\\03',
            'mt5_server'       => 'p01_ts03',
            'mt5_login_id'     => 'MTR90000',
            'language'         => 'EN',
            'cs_email'         => 'test_cs@bin.com',
            'sub_account_type' => 'financial'
        };
        undef @identify_args;
        undef @track_args;
        undef @emitter_args;
        undef @transactional_args;

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

        my $sent_properties = {
            loginid                => $test_client->loginid,
            account_type           => 'demo',
            language               => 'EN',
            mt5_group              => 'demo\\p01_ts03\\financial\\svg_std_usd\\03',
            mt5_loginid            => 'MTR90000',
            sub_account_type       => 'financial',
            client_first_name      => $test_client->first_name,
            type_label             => ucfirst $type_label,
            mt5_integer_id         => '90000',
            brand                  => 'deriv',
            mt5_server_location    => 'Frankfurt',
            mt5_server_region      => 'Europe',
            mt5_server             => 'p01_ts03',
            mt5_server_environment => 'Deriv-Demo',
            lang                   => 'ID',
            mt5_dashboard_url      => 'https://app.deriv.com/mt5?lang=id',
            live_chat_url          => 'https://deriv.com/id/?is_livechat_open=true'
        };

        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'track_mt5_signup',
            properties => $sent_properties
            },
            'properties are set properly for new mt5 account event';

        is scalar(@identify_args), 0, 'Identify is not triggered';

        my ($transactional_customer, $transactional_args) = @transactional_args;

        is_deeply $transactional_args->{message_data}, $sent_properties, 'Transactional email data is correct';
        is $transactional_args->{transactional_message_id}, 'mt5_signup_demo', 'Transactional email id is correct';

        undef @track_args;

        $args->{mt5_login_id} = '';
        like exception { $action_handler->($args); }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);    #deactivate transactional.
    };

    subtest 'mt5 signup track - mt5_signup_financial' => sub {
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);    #activate transactional.
        my $args = {
            loginid            => $test_client->loginid,
            'account_type'     => 'financial',
            'language'         => 'EN',
            'mt5_group'        => 'real\\p01_ts01\\financial\\bvi_std_usd',
            'mt5_server'       => 'p01_ts01',
            'mt5_login_id'     => 'MTR90000',
            'language'         => 'EN',
            'cs_email'         => 'test_cs@bin.com',
            'sub_account_type' => 'financial'
        };
        undef @identify_args;
        undef @track_args;
        undef @emitter_args;
        undef @transactional_args;

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

        my $sent_properties = {
            loginid                => $test_client->loginid,
            account_type           => 'financial',
            language               => 'EN',
            mt5_group              => 'real\\p01_ts01\\financial\\bvi_std_usd',
            mt5_loginid            => 'MTR90000',
            sub_account_type       => 'financial',
            client_first_name      => $test_client->first_name,
            type_label             => ucfirst $type_label,
            mt5_integer_id         => '90000',
            brand                  => 'deriv',
            mt5_server_location    => 'Ireland',
            mt5_server_region      => 'Europe',
            mt5_server             => 'p01_ts01',
            mt5_server_environment => 'DerivBVI-Server',
            lang                   => 'ID',
            mt5_dashboard_url      => 'https://app.deriv.com/mt5?lang=id',
            live_chat_url          => 'https://deriv.com/id/?is_livechat_open=true'
        };

        is_deeply \%args,
            {
            context => {
                active => 1,
                app    => {name => 'deriv'},
                locale => 'id'
            },
            event      => 'track_mt5_signup',
            properties => $sent_properties
            },
            'properties are set properly for new mt5 account event';

        is scalar(@identify_args), 0, 'Identify is not triggered';

        my ($transactional_customer, $transactional_args) = @transactional_args;

        is_deeply $transactional_args->{message_data}, $sent_properties, 'Transactional email data is correct';
        is $transactional_args->{transactional_message_id}, 'mt5_signup_financial', 'Transactional email id is correct';

        undef @track_args;

        $args->{mt5_login_id} = '';
        like exception { $action_handler->($args); }, qr/mt5 loginid is required/, 'correct exception when mt5 loginid is missing';
        is scalar @track_args,    0, 'Track is not triggered';
        is scalar @identify_args, 0, 'Identify is not triggered';
        BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);    #deactivate transactional.
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

        $args->{loginid} = 'MTD90000';
        $args->{color}   = 16711680;

        my $response =
            index($action_handler->($args)->{failure}[0], 'Ignoring color change on demo account');

        is $response, 0, 'correct exception when passed a demo MT5 account';

        $args->{loginid} = 'MT90000';
        $args->{color}   = 16711680;

        $mocked_mt5->mock('get_user', sub { Future->fail({code => "NotFound"}) });
        $mocked_user->mock('new', sub { bless {id => 1}, 'BOM::User' });

        $response =
            index($action_handler->($args)->{failure}[0], 'Account MT90000 not found among the active accounts, changed the status to archived');

        is $response, 0, 'correct exception when MT5 account is not found';

        $mocked_mt5->mock('get_user',    sub { Future->done({login => "MT90000", email => 'test123@test.com'}) });
        $mocked_mt5->mock('update_user', sub { Future->done({login => "MT90000", color => 123}) });

        like exception { $action_handler->($args)->get; }, qr/Could not change client MT90000 color to 16711680/,
            'correct exception when failed to update color field';

        $mocked_mt5->mock('update_user', sub { Future->done({login => "MT90000", color => 16711680}) });

        $mocked_user->mock('id', sub { 1 })->mock('bom_real_loginids', sub { ('CR90000', 'CR90001') });
        my $result = $action_handler->($args)->get;
        ok $result, 'Success mt5 color change result';

        $mocked_mt5->unmock('get_user');
        $mocked_user->unmock('new')->unmock('id')->unmock('bom_real_loginids');
    };

    subtest 'mt5 color change removed rights' => sub {
        my $args = {
            loginid => 'MTR90000',
            color   => 16711680
        };

        my $action_handler = BOM::Event::Process->new(category => 'track')->actions->{mt5_change_color};

        $mocked_mt5->mock('get_user', sub { Future->done({login => "MTR90000", email => 'test123@test.com', rights => 'test'}) });
        my $update_user_rights;
        $mocked_mt5->mock(
            'update_user',
            sub {
                my $user_details = shift;
                $update_user_rights = $user_details->{rights} ? 'exists' : 'deleted';
                return Future->done({login => "MT90000", color => 123});
            });

        like exception { $action_handler->($args)->get; }, qr/Could not change client MTR90000 color to 16711680/,
            'correct exception when failed to update color field';

        is $update_user_rights, 'deleted', 'MT5 User Rights key removed';

        $mocked_mt5->unmock('get_user');
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

subtest 'mt5 inactive account closed - transactional email' => sub {
    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(1);    #activate transactional.
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
    undef @transactional_args;
    undef @track_args;

    $args->{email} = $test_client->{email};
    my $result = $action_handler->($args)->get;
    ok $result, 'Success event result';

    my (undef, %tracked) = $track_args[0]->@*;

    is_deeply \%tracked,
        {
        event   => 'track_mt5_inactive_account_closed',
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

    my ($transactional_customer, $transactional_args) = @transactional_args;
    is $transactional_args->{transactional_message_id}, 'mt5_inactive_account_closed', 'Transactional email id is correct';
    BOM::Config::Runtime->instance->app_config->customerio->transactional_emails(0);    #deactivate transactional.
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

subtest 'tests for loginids sorted by last login' => sub {

    my $day_one   = '2011-03-08 12:59:59';
    my $day_two   = '2011-03-09 12:59:59';
    my $day_three = '2011-03-10 12:59:59';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',

    });
    $client->payment_legacy_payment(
        currency         => 'USD',
        amount           => 100,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $day_three,
        payment_time     => $day_three,
        source           => 1,
    );
    my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'MF',

    });
    $client_mf->payment_legacy_payment(
        currency         => 'USD',
        amount           => 100,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $day_two,
        payment_time     => $day_two,
        source           => 1,
    );
    my $client_vr = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'VRTC',

    });

    $client_vr->payment_legacy_payment(
        currency         => 'USD',
        amount           => 100,
        remark           => 'top up',
        payment_type     => 'credit_debit_card',
        transaction_time => $day_one,
        payment_time     => $day_one,
        source           => 1,
    );

    my $user = BOM::User->create(
        email          => 'rule_client@binary.com',
        password       => 'abcd',
        email_verified => 1,
    );

    $user->add_client($client);
    $user->add_client($client_vr);
    $user->add_client($client_mf);

    is_deeply [BOM::Event::Actions::MT5::sort_login_ids_by_transaction({login_ids => [$user->bom_real_loginids()]})],
        [$client->loginid, $client_mf->loginid], 'loginids are sorted by last login';
    $mocked_user_client->mock('account', shift // sub { undef });
    is_deeply [BOM::Event::Actions::MT5::sort_login_ids_by_transaction({login_ids => [$user->bom_real_loginids()]})],
        [$client->loginid, $client_mf->loginid], 'loginids are sorted by last login';
    $mocked_user_client->unmock_all;

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
            $mocked_user->mock('bom_real_loginids', shift // sub { ($auto_rescind_test_client->loginid) });
        },
    );

    my %bom_user_client_account_mock = (
        payment_id => sub {
            $mocked_user_client_account->mock('payment_id', shift // sub { '123' });
        },
    );

    my %bom_user_client_mock = (
        new => sub {
            $mocked_user_client->mock('new', shift // sub { bless $sample_bom_user_client, 'BOM::User::Client' });
        },
        get_client_instance => sub {
            $mocked_user_client->mock('get_client_instance', shift // sub { bless $auto_rescind_test_client, 'BOM::User::Client' });
        },
        account => sub {
            $mocked_user_client->mock('account', shift // sub { bless $auto_rescind_test_client, 'BOM::User::Client::Account' });
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
        $bom_user_mock{bom_real_loginids}->(sub { ($auto_rescind_test_client->loginid) });
        $bom_user_client_mock{get_client_instance}->();
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
        $bom_user_client_mock{get_client_instance}->();

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Error getting Deriv Account'}}, 'Got error getting deriv account error';
    };

    subtest 'Deriv Account not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $bom_user_client_mock{new}->(sub { undef; });
        $bom_user_client_mock{get_client_instance}->();

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Deriv Account not found'}}, 'Got deriv account not found error';
    };

    subtest 'Deriv Account currency not found' => sub {
        my $args = {
            mt5_accounts    => ['MTR10000'],
            override_status => 0
        };

        $mt5_deriv_auto_rescind_mock_set->();
        $mt5_deriv_auto_rescind_process_mock_set->();
        $bom_user_client_mock{currency}->(sub { undef; });
        $bom_user_client_mock{get_client_instance}->();
        $bom_user_client_mock{account}->();

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Deriv Account currency not found'}},
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
        $bom_user_client_mock{get_client_instance}->();
        $bom_user_client_mock{validate_payment}->(sub { die {error => 'Generic Error'} });

        my $result = $action_get->($args)->get;
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Validate Payment failed'}}, 'Got validate payment failed error';
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
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Currency not allowed'}}, 'Got currency not allowed error';
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
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Account Disabled'}}, 'Got account disabled error';
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
            {'MTR10000' => {'CR10003' => 'Funds transfer operation completed but error in recording mt5_transfer, archive process skipped'}},
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
        is_deeply $result->{failed_case}, {'MTR10000' => {'CR10003' => 'Payment MT5 Transfer failed - MT5 Balance changes reverted'}},
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
            {'MTR10000' => {'CR10003' => 'Payment MT5 Transfer failed - MT5 Balance modified and may failed to revert. Manual check required.'}},
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
            'testrescind@test.com' => {
                bom_user     => bless($sample_bom_user, 'BOM::User'),
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
            'testrescind@test.com' => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR10003",
                    transferred_deriv_amount   => "10.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR10003"],
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
            'testrescind@test.com' => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR10003",
                    transferred_deriv_amount   => "9.8",
                    transferred_deriv_currency => "EUR",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR10003"],
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
            'testrescind@test.com' => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [$sample_mt5_user],
                MTR10000     => {
                    transferred_deriv          => "CR10003",
                    transferred_deriv_amount   => "10.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "10.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR10003"],
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
            'testrescind@test.com' => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [\%mt5_user_with_balance],
                MTR10000     => {
                    transferred_deriv          => "CR10003",
                    transferred_deriv_amount   => "5.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "5.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR10003"],
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
            'testrescind@test.com' => {
                bom_user     => $sample_bom_user,
                mt5_accounts => [\%mt5_user_with_balance],
                MTR10000     => {
                    transferred_deriv          => "CR10003",
                    transferred_deriv_amount   => "5.00",
                    transferred_deriv_currency => "USD",
                    transferred_mt5_amount     => "5.00",
                    transferred_mt5_currency   => "USD",

                },
                transfer_targets => ["CR10003"],
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
        <b>-</b> MTR10000 (Archived) Transferred USD 10.00 to CR10003 With Value of USD 10.00 <br>
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
        <b>-</b> MTR10000 (Archive Skipped) Transferred USD 10.00 to CR10003 With Value of USD 10.00 <br>
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
        updated_color => {maltainvest => +BOM::Event::Actions::MT5::COLOR_RED}
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

    $rule_fail = 1;

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            for my $mt5_rule_status ('poa_failed', 'poa_outdated', 'proof_failed', 'verification_pending', 'needs_verification') {
                $mt5_status     = $mt5_rule_status;
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
                        $jurisdiction => $mt5_rule_status,
                    },
                    updated_color => {$jurisdiction => +BOM::Event::Actions::MT5::COLOR_RED}
                    },
                    "expected results $jurisdiction $str_status => $mt5_rule_status";

                cmp_deeply $emissions,
                    [{
                        mt5_change_color => {
                            loginid => 'MTR000005',
                            color   => +BOM::Event::Actions::MT5::COLOR_RED,
                        }}
                    ],
                    'Expected change color emission';
                cmp_deeply $status_updates, {MTR000005 => $mt5_rule_status}, 'status changed';
                cmp_deeply $log->msgs, [], 'No warnings';
            }
        }
    }

    ## test the statuses across jurisdictions
    ## expected result = poa_failed
    ## color swap to COLOR_RED expected

    $rule_fail = 1;

    for my $jurisdiction ('bvi', 'vanuatu', 'labuan', 'maltainvest') {
        for my $status ('poa_pending', 'poa_failed', 'poa_rejected', 'proof_failed', 'verification_pending', 'poa_outdated', undef) {
            for my $mt5_rule_status ('poa_pending', 'poa_rejected') {
                $mt5_status     = $mt5_rule_status;
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
                        $jurisdiction => $mt5_rule_status,
                    },
                    updated_color => {$jurisdiction => +BOM::Event::Actions::MT5::COLOR_NONE}
                    },
                    "expected results $jurisdiction $str_status => $mt5_rule_status";

                cmp_deeply $emissions,
                    [{
                        mt5_change_color => {
                            loginid => 'MTR000005',
                            color   => +BOM::Event::Actions::MT5::COLOR_NONE,
                        }}
                    ],
                    'Expected change color emission';
                cmp_deeply $status_updates, {MTR000005 => $mt5_rule_status}, 'status changed';
                cmp_deeply $log->msgs, [], 'No warnings';
            }
        }
    }

    ## test the statuses across jurisdictions
    ## expected result = undef status
    ## color swap to COLOR_NONE expected if status undefined

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
                updated_color => {$jurisdiction => +BOM::Event::Actions::MT5::COLOR_NONE}
                },
                "expected results $jurisdiction $str_status => undef";

            cmp_deeply $emissions,
                [{
                    mt5_change_color => {
                        loginid => 'MTR000005',
                        color   => +BOM::Event::Actions::MT5::COLOR_NONE,
                    }}
                ],
                'Expected change color emission';

            cmp_deeply $status_updates, {MTR000005 => undef}, 'status changed';
            cmp_deeply $log->msgs, [], 'No warnings';
        }
    }
    $rule_engine_mock->unmock_all;
    $user_mock->unmock_all;
};

subtest 'mt5_archive_accounts' => sub {

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{mt5_archive_accounts};
    my $mocked_actions = Test::MockModule->new('BOM::Event::Actions::MT5');
    my $emitter_mock   = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $mocked_time    = Test::MockModule->new('Time::Moment');

    my $args      = {};
    my $emissions = [];
    my $result;

    $emitter_mock->mock(
        'emit',
        sub {
            push $emissions->@*, {@_};
        });

    subtest 'Not found' => sub {

        $mocked_actions->mock('_get_mt5_account', sub { undef });
        like exception { $action_handler->($args)->get; }, qr/Must provide list of MT5 loginids/, 'correct exception when loginids are missing';

        $args   = {loginids => ['MTR90000']};
        $result = $action_handler->($args)->get;
        ok $result, 'Successful request';

        # Account not found, missing from users.loginid table
        cmp_deeply $emissions,
            [{
                send_email => {
                    email_content_is_html => 1,
                    from                  => 'system@deriv.com',
                    message               => [
                        "<p>MT5 Archival request result</p>\n    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>",
                        "<tr><td>MTR90000</td><td>Not Archived</td><td>Unknown</td><td>Account not found</td></tr>",
                        "</table>"
                    ],
                    subject => 'MT5 Archival request result ',
                    to      => 'x-trading-ops@deriv.com',
                },
            },
            ],
            'Correct email when account not found';
    };

    subtest 'Already archived' => sub {

        $mocked_actions->mock('_get_mt5_account', sub { return [1, 'archived', '']; });
        $emissions = [];
        $args      = {loginids => ['MTR90000']};

        $result = $action_handler->($args)->get;
        ok $result, 'Success mt5 archive request';

        cmp_deeply $emissions,
            [{
                send_email => {
                    email_content_is_html => 1,
                    from                  => 'system@deriv.com',
                    message               => [
                        "<p>MT5 Archival request result</p>\n    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>",
                        "<tr><td>MTR90000</td><td>Not Archived</td><td>Undefined</td><td>Account already archived</td></tr>",
                        "</table>"
                    ],
                    subject => 'MT5 Archival request result ',
                    to      => 'x-trading-ops@deriv.com',
                },
            },
            ],
            'Correct email when account already archived';
    };

    subtest 'IB accounts' => sub {

        $mocked_actions->mock(
            '_get_mt5_account',
            sub {
                my $params = shift;
                return [1, 'poa_failed',  '{"group":"real\\\\p01_ts02\\\\some_bvi_group"}'] if $params->{loginid} eq 'MTR90000';
                return [2, 'poa_pending', '']                                               if $params->{loginid} eq 'MTR90001';
            });

        $mocked_actions->mock(
            '_ib_affiliate_account_type',
            sub {
                my $params = shift;
                return 'main'      if $params->{loginid} eq 'MTR90000' and $params->{binary_user_id} == 1;
                return 'technical' if $params->{loginid} eq 'MTR90001' and $params->{binary_user_id} == 2;
            });

        $emissions = [];
        $args      = {loginids => ['MTR90000', 'MTR90001']};

        $result = $action_handler->($args)->get;
        ok $result, 'Success mt5 archive request';

        cmp_deeply $emissions, [{
                'send_email' => {
                    'to'      => 'x-trading-ops@deriv.com',
                    'subject' => 'MT5 Archival request result ',
                    'message' => [
                        '<p>MT5 Archival request result</p>
    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>',
                        '<tr><td>MTR90000</td><td>Not Archived</td><td>real\\p01_ts02\\some_bvi_group</td><td>IB main account</td></tr>',
                        '<tr><td>MTR90001</td><td>Not Archived</td><td>Undefined</td><td>IB technical account</td></tr>',
                        '</table>'
                    ],
                    'email_content_is_html' => 1,
                    'from'                  => 'system@deriv.com'
                }}
            ],
            'IB accounts correct email emission';

        $mocked_actions->unmock('_ib_affiliate_account_type');
    };

    subtest 'Successful Archivals' => sub {

        $mocked_actions->mock(
            '_get_mt5_account',
            sub {
                my $params = shift;
                return [1, 'poa_failed',  '{"group":"real\\\\p01_ts02\\\\some_bvi_group"}']     if $params->{loginid} eq 'MTR90000';
                return [2, 'poa_pending', '{"group":"real\\\\p01_ts02\\\\some_vanuatu_group"}'] if $params->{loginid} eq 'MTR90001';
            });

        $mocked_mt5->mock(
            'get_user',
            sub {
                my $loginid = shift;
                return Future->done({
                    balance => ($loginid eq 'MTR90000' ? 0 : 100),
                    login   => $loginid
                });
            });

        $mocked_time->mock('now', sub { return Time::Moment->from_string('2023-07-25T09:38:48.819049Z'); });
        $mocked_mt5->mock('get_open_orders_count',    sub { return Future->done({total    => 0}); });
        $mocked_mt5->mock('get_open_positions_count', sub { return Future->done({total    => 0}); });
        $mocked_mt5->mock('get_group',                sub { return Future->done({currency => 'USD'}); });
        $mocked_mt5->mock('withdrawal',               sub { return Future->done({status   => 1}); });
        $mocked_actions->mock('_archive_mt5_account', async sub { return 1; });

        $emissions = [];
        $result    = $action_handler->($args)->get;
        ok $result, 'Success mt5 archive request';

        cmp_deeply $emissions, [{
                'send_email' => {
                    'to'      => 'x-trading-ops@deriv.com',
                    'subject' => 'MT5 Archival request result ',
                    'message' => [
                        '<p>MT5 Archival request result</p>
    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>',
                        '<tr><td>MTR90000</td><td>Archived</td><td>real\\p01_ts02\\some_bvi_group</td><td>Archived successfully, account had zero balance</td></tr>',
                        '<tr><td>MTR90001</td><td>Archived</td><td>real\\p01_ts02\\some_vanuatu_group</td><td>[2023-07-25T09:38:48.819049Z] Transfer from MT5 login: MTR90001 to binary account CR10000 USD 100</td></tr>',
                        '</table>'
                    ],
                    'email_content_is_html' => 1,
                    'from'                  => 'system@deriv.com'
                }}
            ],
            'Correct email emission';
    };

    subtest 'Successful archival with linked wallet' => sub {
        my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code => 'CR',
            email       => 'svg_wallet_archival@gmail.com',
        });
        $test_client->set_default_account('USD');

        my $test_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
            broker_code  => 'CRW',
            account_type => 'doughflow',
            email        => 'svg_wallet_archival@gmail.com',
        });
        $test_wallet->set_default_account('USD');

        my $user = BOM::User->create(
            email          => $test_client->email,
            password       => "testpassword",
            email_verified => 1,
        );
        $user->add_client($test_client);
        $user->add_client($test_wallet);

        my $mt5_loginid = 'MTR10003';
        $user->add_loginid($mt5_loginid, 'mt5', 'real', 'USD', {}, $test_wallet->loginid);

        $mocked_actions->redefine(
            '_get_mt5_account',
            sub {
                return [$user->id, undef, '{"group":"real\\\\p01_ts02\\\\some_bvi_group"}'];
            });

        $mocked_mt5->redefine(
            'get_user',
            sub {
                my $loginid = shift;
                return Future->done({
                    balance => 100,
                    login   => $mt5_loginid
                });
            });

        $mocked_time->redefine('now', sub { return Time::Moment->from_string('2023-07-25T09:38:48.819049Z'); });
        $mocked_mt5->redefine('get_open_orders_count',    sub { return Future->done({total    => 0}); });
        $mocked_mt5->redefine('get_open_positions_count', sub { return Future->done({total    => 0}); });
        $mocked_mt5->redefine('get_group',                sub { return Future->done({currency => 'USD'}); });
        $mocked_mt5->redefine('withdrawal',               sub { return Future->done({status   => 1}); });
        $mocked_actions->redefine('_archive_mt5_account', async sub { return 1; });

        $emissions = [];
        $result    = $action_handler->({
                loginids => [$mt5_loginid],
            })->get;
        ok $result, 'Success mt5 archive request';

        is $test_wallet->account->balance, '100.00', 'Wallet balance is 100';
        is $test_client->account->balance, 0,        'Trading account balance is 0';
    };

    $mocked_actions->unmock_all;
    $emitter_mock->unmock_all;
    $mocked_time->unmock_all;

};

subtest 'mt5_svg_migration_requested' => sub {
    $mocked_user->unmock_all;
    $mocked_user_client->unmock_all;
    $mocked_mt5->unmock_all;

    my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @datadog_args;
    $mocked_datadog->mock('stats_event', sub { @datadog_args = @_ });

    my $update_user_call_params;
    $mocked_mt5->mock('update_user', sub { $update_user_call_params = shift; return Future->done(1); });

    $mocked_emitter->mock(
        'emit',
        sub {
            push @emitter_args, @_;
            return 1;
        });

    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'svg_migrade_active_trade@gmail.com',
    });

    my $user = BOM::User->create(
        email          => $test_client->email,
        password       => "testpassword",
        email_verified => 1,
    );
    $user->add_client($test_client);
    $user->add_loginid('MTR10000', 'mt5', 'real', 'USD', {});
    $user->add_loginid('MTR10001', 'mt5', 'real', 'USD', {});

    my $sample_mt5_account = {
        account_type          => "real",
        balance               => "0.00",
        comment               => "",
        country               => "id",
        currency              => "USD",
        display_balance       => "0.00",
        email                 => "dummy\@gmail.com",
        group                 => "real\\p01_ts01\\financial\\svg_std-hr_usd",
        landing_company_short => "svg",
        leverage              => 1000,
        login                 => "MTR1000000",
        market_type           => "financial",
        name                  => "dummy name",
        status                => undef,
        sub_account_category  => "",
        sub_account_type      => "financial",
        comment               => '',
        active                => 1
    };

    my $sample_mt5_group = {
        financial_svg      => 'real\\p01_ts01\\financial\\svg_std_usd',
        financial_bvi      => 'real\\p01_ts01\\financial\\bvi_std_usd',
        financial_vanuatu  => 'real\\p01_ts01\\financial\\vanuatu_std_usd',
        synthetic_svg      => 'real\\p01_ts01\\synthetic\\svg_std_usd',
        synthetic_bvi      => 'real\\p01_ts01\\synthetic\\bvi_std_usd',
        synthetic_vanuatu  => 'real\\p01_ts01\\synthetic\\vanuatu_std_usd',
        swap_free_svg      => 'real\p01_ts01\all\svg_std-sf_usd',
        financial_lim_svg  => 'real\\p01_ts01\\financial\\svg_lim_usd',
        financial_svg_demo => 'demo\\p01_ts01\\financial\\svg_std_usd',
    };

    $mocked_user->mock('update_loginid_status', sub { return 1; });
    $mocked_mt5_async->mock('get_open_orders_count',    sub { return Future->done({total => 0}); });
    $mocked_mt5_async->mock('get_open_positions_count', sub { return Future->done({total => 0}); });

    my $action_handler = BOM::Event::Process->new(category => 'generic')->actions->{mt5_svg_migration_requested};
    my $action_get     = sub { $action_handler->(shift)->get->get };

    subtest 'Params check error' => sub {
        my $args = {
            client_loginid => 'CR123',
        };
        like exception { $action_get->($args); }, qr/No client found/, 'correct exception when incorrect client_loginid provided';

        $args->{client_loginid} = $test_client->loginid;
        like exception { $action_get->($args); }, qr/Need to provide market_type argument/, 'correct exception when merket_type not provided';

        $args->{client_loginid} = $test_client->loginid;
        $args->{market_type}    = 'financial';
        like exception { $action_get->($args); }, qr/Need to provide jurisdiction argument/, 'correct exception when jurisdiction not provided';
    };

    subtest 'No account migrated with just bvi/vanuatu with no svg' => sub {
        @emitter_args = ();

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};
        $bvi_financial->{market_type} = 'financial';

        my $vanuatu_financial = clone $sample_mt5_account;
        $vanuatu_financial->{group}       = $sample_mt5_group->{financial_vanuatu};
        $vanuatu_financial->{market_type} = 'financial';

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $vanuatu_financial]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
    };

    subtest 'No account migrated with just demo svg' => sub {

        my $svg_financial_demo = clone $sample_mt5_account;
        $svg_financial_demo->{group}        = $sample_mt5_group->{financial_svg_demo};
        $svg_financial_demo->{account_type} = 'demo';
        $svg_financial_demo->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};
        $bvi_financial->{market_type} = 'financial';

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_demo]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
    };

    subtest 'Real account migrated (without open order or position)' => sub {

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_demo = clone $sample_mt5_account;
        $svg_financial_demo->{login}        = 'MTR1000001';
        $svg_financial_demo->{group}        = $sample_mt5_group->{financial_svg_demo};
        $svg_financial_demo->{market_type}  = 'financial';
        $svg_financial_demo->{account_type} = 'demo';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_demo, $svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';

        @emitter_args = ();
    };

    subtest 'Only real account migrated when demo svg exist (with open order or position)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_demo = clone $sample_mt5_account;
        $svg_financial_demo->{login}        = 'MTR1000001';
        $svg_financial_demo->{group}        = $sample_mt5_group->{financial_svg_demo};
        $svg_financial_demo->{account_type} = 'demo';
        $svg_financial_demo->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_demo, $svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args,
            [
            'mt5_change_color',
            {
                loginid => 'MTR1000000',
                color   => 0
            }
            ],
            'Correct color change emission (BLACK)';

        @emitter_args = ();
    };

    subtest 'No real synthetic svg account migrated when event triggered with market type financial (with open order or position)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_synthetic_real = clone $sample_mt5_account;
        $svg_synthetic_real->{group}        = $sample_mt5_group->{synthetic_svg};
        $svg_synthetic_real->{account_type} = 'real';
        $svg_synthetic_real->{market_type}  = 'synthetic';

        my $svg_financial_demo = clone $sample_mt5_account;
        $svg_financial_demo->{login}        = 'MTR1000001';
        $svg_financial_demo->{group}        = $sample_mt5_group->{financial_svg_demo};
        $svg_financial_demo->{account_type} = 'demo';
        $svg_financial_demo->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_demo, $svg_synthetic_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
    };

    subtest 'Only real financial account migrated when swap free financial exist (with open_order_position_status)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_swap_free = clone $sample_mt5_account;
        $svg_financial_swap_free->{login}                = 'MTR1000001';
        $svg_financial_swap_free->{group}                = $sample_mt5_group->{swap_free_svg};
        $svg_financial_swap_free->{account_type}         = 'real';
        $svg_financial_swap_free->{market_type}          = 'financial';
        $svg_financial_swap_free->{sub_account_category} = 'swap_free';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_swap_free, $svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args,
            [
            'mt5_change_color',
            {
                loginid => 'MTR1000000',
                color   => 0
            }
            ],
            'Correct color change emission (BLACK)';

        @emitter_args = ();
    };

    subtest 'No real financial account migrated when lim financial exist (with open_order_position_status)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_lim = clone $sample_mt5_account;
        $svg_financial_lim->{login}        = 'MTR1000001';
        $svg_financial_lim->{group}        = $sample_mt5_group->{financial_lim_svg};
        $svg_financial_lim->{account_type} = 'real';
        $svg_financial_lim->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_lim, $svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
        is_deeply \@datadog_args,
            ['MT5AccountMigrationSkipped', 'Aborted migration for ' . $test_client->loginid . ' on financial/bvi', {alert_type => 'warning'}],
            'Correct warning';
    };

    subtest 'No real financial account migrated when IB MT5 exist (with open_order_position_status)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_ib = clone $sample_mt5_account;
        $svg_financial_ib->{login}        = 'MTR1000001';
        $svg_financial_ib->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_ib->{account_type} = 'real';
        $svg_financial_ib->{market_type}  = 'financial';
        $svg_financial_ib->{comment}      = 'IB';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_ib, $svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
        is_deeply \@datadog_args,
            ['MT5AccountMigrationSkipped', 'Aborted migration for ' . $test_client->loginid . ' on financial/bvi', {alert_type => 'warning'}],
            'Correct warning';
    };

    subtest 'Duplicate financial account migrated when comment is undefined (with open_order_position_status)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $duplicate_svg_financial_real = clone $svg_financial_real;
        $duplicate_svg_financial_real->{login} = 'MTR1000003';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_real, $duplicate_svg_financial_real]};
        my $result = $action_get->($args);

        is_deeply \@emitter_args,
            [
            'mt5_change_color',
            {
                loginid => 'MTR1000000',
                color   => 0
            },
            'mt5_change_color',
            {
                loginid => 'MTR1000003',
                color   => 0
            }
            ],
            'Correct color change emmissions';

        @emitter_args = ();
    };

    subtest 'No real financial account migrated when comment is undefined (with open_order_position_status)' => sub {

        $mocked_mt5_async->mock('get_open_orders_count', sub { return Future->done({total => 1}); });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $svg_financial_ib = clone $sample_mt5_account;
        $svg_financial_ib->{login}        = 'MTR1000001';
        $svg_financial_ib->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_ib->{account_type} = 'real';
        $svg_financial_ib->{market_type}  = 'financial';
        delete $svg_financial_ib->{comment};

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_ib, $svg_financial_real]};

        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
    };

    $mocked_user->unmock_all;

    subtest 'mt5_svg_migration_requested bom rpc integration test' => sub {

        $mocked_user->mock('update_loginid_status', sub { return 1; });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        $mocked_mt5_async->mock('get_open_orders_count',    sub { return Future->done({total => 0}); });
        $mocked_mt5_async->mock('get_open_positions_count', sub { return Future->done({total => 1}); });

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_real]};

        my $result = $action_get->($args);

        is_deeply \@emitter_args,
            [
            'mt5_change_color',
            {
                loginid => 'MTR1000000',
                color   => 0
            }
            ],
            'Correct color change emission (BLACK)';
        is $update_user_call_params->{login}, 'MTR1000000', 'Correct loginid passed to update_user';
        is $update_user_call_params->{rights}, Deriv::TradingPlatform::MT5::UserRights::get_value(qw(trade_disabled enabled)),
            'Correct rights passed to update_user';

        $update_user_call_params = undef;
        @emitter_args            = ();
    };

    subtest 'mt5_svg_migration_requested bom rpc integration test' => sub {

        $mocked_user->mock('update_loginid_status', sub { return 1; });

        my $svg_financial_real = clone $sample_mt5_account;
        $svg_financial_real->{group}        = $sample_mt5_group->{financial_svg};
        $svg_financial_real->{account_type} = 'real';
        $svg_financial_real->{market_type}  = 'financial';

        my $bvi_financial = clone $sample_mt5_account;
        $bvi_financial->{login}       = 'MTR1000002';
        $bvi_financial->{market_type} = 'financial';
        $bvi_financial->{group}       = $sample_mt5_group->{financial_bvi};

        $mocked_mt5_async->mock('get_open_orders_count',    sub { return Future->done({total => 0}); });
        $mocked_mt5_async->mock('get_open_positions_count', sub { return Future->done({total => 0}); });

        my $args = {
            client_loginid => $test_client->loginid,
            market_type    => 'financial',
            jurisdiction   => 'bvi',
            logins         => [$bvi_financial, $svg_financial_real]};

        my $result = $action_get->($args);

        is_deeply \@emitter_args, [], 'Correct absence of color change emission';
        @emitter_args = ();
    };

    $mocked_user->unmock_all;
    $mocked_mt5_async->unmock_all;
    $mocked_emitter->unmock_all;
};

subtest 'mt5_archive_accounts' => sub {
    my $user = BOM::User->create(
        email          => 'test@test.test',
        password       => 'supahsus',
        email_verified => 1,
    );

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => 'test@test.test',
    });

    my $action_handler   = BOM::Event::Process->new(category => 'generic')->actions->{mt5_archive_accounts};
    my $emitter_mock     = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my $mt5_actions_mock = Test::MockModule->new('BOM::Event::Actions::MT5');
    my $mocked_user      = Test::MockModule->new('BOM::User');
    my $mocked_mt5       = Test::MockModule->new('BOM::MT5::User::Async');
    my $time_mock        = Test::MockModule->new('Time::Moment');

    my $get_mt5_account_from_db_values = {
        'MTR1000001' => undef,                                                                    # Account found
        'MTR1000002' => [1, 'archived',             encode_json({group => 'some_svg_group'})],    # Account already archived
        'MTR1000003' => [2, '',                     encode_json({group => 'some_svg_group'})],    # Account has open orders or positions
        'MTR1000004' => [3, '',                     encode_json({group => 'some_svg_group'})],    # Account has a negative balance
        'MTR1000005' => [4, '',                     encode_json({group => 'some_svg_group'})],    # No active CR account found to withdraw
        'MTR1000006' => [5, 'proof_failed',         encode_json({group => 'some_svg_group'})],    # User not found
        'MTR1000007' => [6, 'verification_pending', encode_json({group => 'some_svg_group'})],    # Failed to perform withdrawal
        'MTR1000008' => [7, 'poa_failed',           encode_json({group => 'some_bvi_group'})],    # Archived successfully, account had zero balance
        'MTR1000009' => [8, '', encode_json({group => 'some_svg_group'})],    # [%s] Transfer from MT5 login: %s to binary account %s %s %s
    };

    $mt5_actions_mock->mock(
        '_get_mt5_account',
        sub {
            my $arg     = shift;
            my $loginid = $arg->{loginid};
            return $get_mt5_account_from_db_values->{$loginid};
        });

    $mocked_mt5->mock('get_open_orders_count', sub { Future->done({total => 0}); })->mock(
        'get_open_positions_count',
        sub {
            my $loginid = shift;
            return Future->fail({code  => 'NotFound'}) if $loginid eq 'MTR1000006';
            return Future->done({total => 1})          if $loginid eq 'MTR1000003';
            Future->done({total => 0});
        }
    )->mock(
        'get_user',
        sub {
            my $loginid = shift;
            return Future->done({balance => -0.01}) if $loginid eq 'MTR1000004';
            return Future->done({balance => 0.01})  if $loginid eq 'MTR1000005' or $loginid eq 'MTR1000007' or $loginid eq 'MTR1000009';
            return Future->done({balance => 0.0});
        });

    my $first_disabled_account = 0;
    $mocked_user->mock('new', sub { $user })->mock('bom_real_loginids', sub { ['CR10000'] })->mock(
        'accounts_by_category',
        sub {
            $first_disabled_account++;
            my $client = BOM::User::Client->new({loginid => 'CR10000'});
            $client->account('USD');
            return {($first_disabled_account == 1 ? 'disabled' : 'enabled') => [$client]};
        });

    # mock get_group
    $mocked_mt5->mock('get_group', sub { Future->done({currency => 'USD'}); })
        ->mock('withdrawal',
        sub { my $args = shift; return Future->done({error => 1}) if $args->{login} eq 'MTR1000007'; Future->done({status => 1}) });

    my @archive_params;
    $mt5_actions_mock->mock('_archive_mt5_account', sub { push @archive_params, \@_; Future->done(1); });

    my $email_params;
    $emitter_mock->mock('emit', sub { $email_params = [@_]; });

    my $args = {
        loginids    => ['MTR1000001', 'MTR1000002', 'MTR1000003', 'MTR1000004', 'MTR1000005', 'MTR1000006', 'MTR1000007', 'MTR1000008', 'MTR1000009'],
        email_to    => 'compops@compops.com',
        email_title => 'TESTING MT5 Archival request result',
    };

    $time_mock->mock('now', sub { Time::Moment->from_string('2023-10-23T14:33:32.579880Z'); });
    my $result = $action_handler->($args)->get;

    cmp_deeply $email_params, [
        'send_email',
        {
            'from'                  => 'system@deriv.com',
            'to'                    => 'compops@compops.com',
            'email_content_is_html' => 1,
            'subject'               => 'TESTING MT5 Archival request result',
            'message'               => [
                '<p>MT5 Archival request result</p>
    <table border=1><tr><th>Loginid</th><th>Status</th><th>Group</th><th>Comment</th></tr>',
                '<tr><td>MTR1000001</td><td>Not Archived</td><td>Unknown</td><td>Account not found</td></tr>',
                '<tr><td>MTR1000002</td><td>Not Archived</td><td>some_svg_group</td><td>Account already archived</td></tr>',
                '<tr><td>MTR1000003</td><td>Not Archived</td><td>some_svg_group</td><td>Account has open orders or positions</td></tr>',
                '<tr><td>MTR1000004</td><td>Not Archived</td><td>some_svg_group</td><td>The account has a negative balance</td></tr>',
                '<tr><td>MTR1000005</td><td>Not Archived</td><td>some_svg_group</td><td>No active CR account found to withdraw</td></tr>',
                '<tr><td>MTR1000006</td><td>Not Archived</td><td>some_svg_group</td><td>Can\'t check MT5 orders and positions, account doesn\'t exist on MT5</td></tr>',
                '<tr><td>MTR1000007</td><td>Not Archived</td><td>some_svg_group</td><td>Failed to perform withdrawal</td></tr>',
                '<tr><td>MTR1000008</td><td>Archived</td><td>some_bvi_group</td><td>Archived successfully, account had zero balance</td></tr>',
                '<tr><td>MTR1000009</td><td>Archived</td><td>some_svg_group</td><td>[2023-10-23T14:33:32.579880Z] Transfer from MT5 login: MTR1000009 to binary account CR10000 USD 0.01</td></tr>',
                '</table>'
            ]}
        ],
        'correct email params';

    $emitter_mock->unmock_all;
    $mt5_actions_mock->unmock_all;
    $mocked_user->unmock_all;
    $mocked_mt5->unmock_all;
    $time_mock->unmock_all;
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
    my $non_existing_transaction_id_parameters = clone $parameters;
    $non_existing_transaction_id_parameters->{transaction_id} = 999999;
    $result = BOM::Event::Process->new(category => 'mt5_retryable')
        ->process({type => 'mt5_deposit_retry', details => $non_existing_transaction_id_parameters});
    like($result->failure, qr/Cannot find transaction id: 999999/, 'Transaction not found test');

    # Test for a demo deposit
    my $demo_parameters = clone $parameters;
    $demo_parameters->{server} = 'demo_p01_ts03';
    $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $demo_parameters});
    like($result->failure, qr/Do not need to try demo deposit/, 'Demo deposit test');

    subtest 'skip deposit retry if deal_get_batch fail' => sub {
        my $mock_http_tiny = Test::MockModule->new('HTTP::Tiny');
        my $app_config     = BOM::Config::Runtime->instance->app_config;
        $app_config->system->mt5->http_proxy->real->p01_ts03(1);
        $mock_mt5->unmock_all;

        # Error Not Found error
        $mock_http_tiny->mock(
            post => sub {
                return {
                    status  => 200,
                    content => '{"message":"Not found","code":"13","error":"ERR_NOTFOUND"}'
                };
            });
        $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $parameters});
        isa_ok $result, 'Future';
        is $result->failure->{code}, 'NotFound', 'skip deposit retry attempt if deal_get_batch got NotFound error';

        # Connection timeout error
        $mock_http_tiny->mock(
            post => sub {
                return {
                    status  => 599,
                    content => 'Timed out while waiting for socket to become ready for reading'
                };
            });
        $result = BOM::Event::Process->new(category => 'mt5_retryable')->process({type => 'mt5_deposit_retry', details => $parameters});
        isa_ok $result, 'Future';
        is $result->failure->{code}, 'NonSuccessResponse', 'skip deposit retry attempt if deal_get_batch got Connection timeout error';

        $mock_http_tiny->unmock_all;
        $app_config->system->mt5->http_proxy->real->p01_ts03(0);
    };

    $mocked_actions->unmock_all;
    $mock_mt5->unmock_all;
};

subtest '_get_loginids_for_mt5_transfer function' => sub {
    my $email       = 'loginids_for_mt5_transfer@example.com';
    my $test_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });
    $test_client->set_default_account('USD');

    my $user = BOM::User->create(
        email          => $email,
        password       => "testpassword",
        email_verified => 1,
    );
    $user->add_client($test_client);
    my $mt5_loginid1 = 'MTR10004';
    $user->add_loginid($mt5_loginid1, 'mt5', 'real', 'USD', {});

    my @login_ids = BOM::Event::Actions::MT5::_get_loginids_for_mt5_transfer($user, $mt5_loginid1);

    is_deeply \@login_ids, [$test_client->loginid], 'Real money account loginid is returned';

    my $test_client1 = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
        email       => $email,
    });
    $test_client1->set_default_account('BTC');
    $user->add_client($test_client1);

    @login_ids = BOM::Event::Actions::MT5::_get_loginids_for_mt5_transfer($user, $mt5_loginid1);

    is_deeply \@login_ids, [$test_client->loginid, $test_client1->loginid], 'If we have multiple real money accounts, all loginids are returned';

    my $test_wallet = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code  => 'CRW',
        account_type => 'doughflow',
        email        => 'svg_wallet_archival@gmail.com',
    });
    $test_wallet->set_default_account('USD');
    $user->add_client($test_wallet);

    my $mt5_loginid2 = 'MTR10005';
    $user->add_loginid($mt5_loginid2, 'mt5', 'real', 'USD', {}, $test_wallet->loginid);

    @login_ids = BOM::Event::Actions::MT5::_get_loginids_for_mt5_transfer($user, $mt5_loginid2);
    is_deeply \@login_ids, [$test_wallet->loginid], 'If mt5 account is linked to wallet, only wallet loginid is returned';

    @login_ids = BOM::Event::Actions::MT5::_get_loginids_for_mt5_transfer($user, $mt5_loginid1);
    is_deeply \@login_ids, [$test_client->loginid, $test_client1->loginid, $test_wallet->loginid],
        'If mt5 account is not linked to wallet, all loginids are returned';
};

done_testing();
