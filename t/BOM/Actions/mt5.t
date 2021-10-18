use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Time::Moment;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Event::Actions::MT5;
use Test::MockModule;
use BOM::User;
use DataDog::DogStatsd::Helper;
use BOM::Platform::Context qw(localize request);
use BOM::Event::Process;
use BOM::Test::Email qw(mailbox_clear mailbox_search);
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
$mocked_emitter->mock('emit', sub { @emitter_args = @_ });
my $mocked_datadog = Test::MockModule->new('DataDog::DogStatsd::Helper');
my @datadog_args;
$mocked_datadog->mock('stats_inc', sub { @datadog_args = @_ });
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

        my $action_handler = BOM::Event::Process::get_action_mappings()->{new_mt5_signup};
        my $result         = $action_handler->($args)->get;
        ok $result, 'Success mt5 new account result';

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
                'account_type'         => 'gaming',
                'language'             => 'EN',
                'mt5_group'            => 'real\\p02_ts02\\synthetic\\svg_std_usd',
                'mt5_loginid'          => 'MTR90000',
                'sub_account_type'     => 'financial',
                'client_first_name'    => $test_client->first_name,
                'type_label'           => ucfirst $type_label,
                'mt5_integer_id'       => '90000',
                brand                  => 'deriv',
                mt5_server_location    => 'South Africa',
                mt5_server_region      => 'Africa',
                mt5_server             => 'p02_ts02',
                mt5_server_environment => 'Deriv-Server-02',
                lang                   => 'ID'
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

        my $action_handler = BOM::Event::Process::get_action_mappings()->{mt5_password_changed};

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

    my $action_handler = BOM::Event::Process::get_action_mappings()->{new_mt5_signup};
    is $action_handler->($args)->get, 1, 'Success mt5 new account result';

    is scalar @sanct_args, 0, 'sanctions are not included in signup actions';

    $lc_actions = {signup => [qw(sanctions)]};
    is $action_handler->($args)->get, 1, 'Success mt5 new account result';
    is scalar @sanct_args, 5, 'sanction check is called, because it is included in signup actions';
    is ref($sanct_args[0]), 'BOM::Platform::Client::Sanctions', 'Sanctions object type is correct';
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

subtest 'mt5 account opening mail' => sub {
    # Mocking send_email
    my $mail_args;

    my $mocker_mt5 = Test::MockModule->new('BOM::Event::Actions::MT5');
    $mocker_mt5->mock(
        'send_email',
        sub {
            $mail_args = shift;
            return $mocker_mt5->original('send_email')->($mail_args);
        });

    # We'll permutate brands, mt5 account types and real/demo accounts
    my $setup = {
        brands   => ['deriv',     'binary'],
        types    => ['financial', 'synthetic'],
        category => ['real',      'demo'],
        langs    => ['en',        'es']};

    # Perform tests
    for my $brand (@{$setup->{brands}}) {
        for my $type (@{$setup->{types}}) {
            for my $category (@{$setup->{category}}) {
                for my $lang (@{$setup->{langs}}) {
                    my $subtest = "mt5 $type $category account opening for $brand customer ($lang)";

                    subtest $subtest => sub {
                        # Setup random data
                        my $mt5_client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                            broker_code => 'CR',
                            email       => sprintf('test+%s@binary.com', int(rand(9000000))),
                        });

                        my $mt5_user = BOM::User->create(
                            email          => $mt5_client->email,
                            password       => "some_fancy_sequence_314159265",
                            email_verified => 1,
                        );
                        $mt5_user->add_client($mt5_client);

                        my $generated_loginid = sprintf('MT%s%s', $category eq 'demo' ? 'D' : 'R', int(rand(90000000)));
                        $mt5_user->add_loginid($generated_loginid);

                        # Set up brand request with desired language
                        my $branded_localized_request = BOM::Platform::Context::Request->new(
                            brand_name => $brand,
                            language   => $lang,
                            ($brand eq 'deriv' ? (app_id => $app_id) : ()));
                        request($branded_localized_request);

                        my $server = $category eq 'demo' ? 'p01_ts01' : 'p02_ts02';

                        my $args = {
                            loginid            => $mt5_client->loginid,
                            'account_type'     => 'gaming',
                            'mt5_group'        => sprintf('%s\\%s\\%s\\svg_std_usd', $category, $server, $type),
                            'mt5_login_id'     => $generated_loginid,
                            'language'         => uc $lang,
                            'cs_email'         => 'test_cs@bin.com',
                            'sub_account_type' => $type
                        };

                        mailbox_clear();
                        my $action_handler = BOM::Event::Process::get_action_mappings()->{new_mt5_signup};
                        my $result         = $action_handler->($args)->get;

                        # Note for binary requests we expect undef
                        my $expected_mt5_result = $brand eq 'deriv' ? 1 : undef;
                        is $result, $expected_mt5_result, "Successfull MT5 account opening for $brand customer ($lang), $type $category account";

                        # Note subject is localized
                        my $subject = localize('Your MT5 account is ready!', ucfirst $category);
                        my $email   = mailbox_search(
                            email   => $mt5_client->email,
                            subject => qr/\Q$subject\E/
                        );

                        ok(!$email, 'Email not sent for deriv customer') if $brand eq 'deriv';
                        ok($email,  'Email sent for binary customer')    if $brand eq 'binary';

                        # The next line caused warnings :-/
                        #next unless $email;

                        if ($email) {
                            # If a mail is sent we may test its content
                            subtest 'Email content' => sub {
                                my $brand_ref   = request()->brand;
                                my $mt5_details = parse_mt5_group($args->{mt5_group});
                                my $type_label  = $mt5_details->{market_type};
                                $type_label .= '_stp' if $mt5_details->{sub_account_type} eq 'stp';
                                my $expected_mt5_loginid = $args->{mt5_login_id} =~ s/${\BOM::User->MT5_REGEX}//r;
                                my $expected_mail_args   = {
                                    from          => $brand_ref->emails('no-reply'),
                                    to            => $mt5_client->email,
                                    subject       => $subject,
                                    template_name => 'mt5_account_opening',
                                    template_args => {
                                        mt5_loginid       => $expected_mt5_loginid,
                                        mt5_category      => $category,
                                        mt5_type_label    => ucfirst $type_label =~ s/stp$/STP/r,
                                        mt5_region        => $category eq 'demo' ? 'Europe'     : 'Africa',
                                        mt5_environment   => $category eq 'demo' ? 'Deriv-Demo' : 'Deriv-Server-02',
                                        client_first_name => $mt5_client->first_name,
                                        lang              => $lang,
                                        website_name      => $brand_ref->website_name,
                                        live_chat_url     => $brand_ref->live_chat_url({language => $lang}),
                                        tnc_approval_url  => $brand_ref->tnc_approval_url({language => $lang}),
                                        help_centre_url   => $brand_ref->help_centre_url({language => $lang}),
                                    },
                                    use_email_template => 1,
                                };

                                is_deeply $mail_args, $expected_mail_args, 'Email content is correct';
                            };
                        }
                    };
                }
            }
        }
    }

    $mocker_mt5->unmock_all;
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

    my $action_handler = BOM::Event::Process::get_action_mappings()->{mt5_inactive_notification};

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
            lang         => 'EN'
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
            lang         => 'EN'
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
    );
    request($req);
    my $args = {
        email        => '',
        transferred  => 'CR12345',
        mt5_accounts => [{
                login => 'MT900000',
                type  => 'demo financial'
            },
            {
                login => 'MT900002',
                type  => 'real financial'
            }
        ],
    };

    mailbox_clear();

    my $action_handler = BOM::Event::Process::get_action_mappings()->{mt5_inactive_account_closed};

    like exception { $action_handler->($args) }, qr/invalid email address/i, 'correct exception when mt5 loginid is missing';

    $args->{email} = $test_client->{email};
    my $result = $action_handler->($args);
    ok $result, 'Success event result';

    my $email = mailbox_search(
        email   => $test_client->email,
        subject => qr/Your MT5 account\(s\) have been closed/
    );
    ok $email, 'Account close email is sent';
    like $email->{body}, qr/MT5 demo financial .* MT900000/, 'Archived account 1 is included in the emial body.';
    like $email->{body}, qr/MT5 real financial .* MT900002/, 'Archived account 2 is included in the emial body.';
    like $email->{body},
        qr/Any available balance in your real account\(s\) has been transferred to your Deriv\/Binary.com trading account.\s*\(CR12345\)/,
        'Transferred account appears in the email body';
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

    my $action_handler = BOM::Event::Process::get_action_mappings()->{mt5_inactive_account_closure_report};
    $action_handler->($args);

    my $email = mailbox_search(
        email   => 'i-payments@deriv.com',
        subject => qr/MT5 account closure report/
    );

    ok $email, 'Account closure report email sent';
    like $email->{body}, qr/MT5 account closure report is attached/, 'corrent content';
};

done_testing();
