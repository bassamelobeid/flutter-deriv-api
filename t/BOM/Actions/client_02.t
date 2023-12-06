use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::Event::Actions::Client;
use BOM::User;
use Date::Utility;
use Future::AsyncAwait;

my $loop;
my $handler;

BEGIN {
    # Enable watchdog
    $ENV{IO_ASYNC_WATCHDOG} = 1;
    # Set watchdog interval
    $ENV{IO_ASYNC_WATCHDOG_INTERVAL} = 3;
    # Consumes the above env variables to set watchdog timeout
    require IO::Async::Loop;
    require BOM::Event::QueueHandler;
    $loop = IO::Async::Loop->new;
}

subtest 'POA updated' => sub {

    sub grab_poa_dates {
        my ($user) = @_;

        return $user->dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM users.poa_issuance WHERE binary_user_id = ?', {Slice => {}}, $user->id);
            });
    }

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $user = BOM::User->create(
        email    => 'error+test@test.com',
        password => "hello",
    );

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->save;

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $best_issue_date;
    my $best_verified_date;
    $doc_mock->mock(
        'best_poa_date',
        sub {
            my ($self, $doc_category, $date_category) = @_;

            return Date::Utility->new($best_issue_date)    if $best_issue_date    && $date_category eq 'best_issue_date';
            return Date::Utility->new($best_verified_date) if $best_verified_date && $date_category eq 'best_verified_date';
            return undef;
        });

    my $exception = exception {
        BOM::Event::Actions::Client::poa_updated({
                loginid => undef,
            })->get;
    };

    ok $exception =~ /No client login ID supplied/, 'Expected exception if no loginid is supplied';

    $exception = exception {
        BOM::Event::Actions::Client::poa_updated({
                loginid => 'CR0',
            })->get;
    };

    ok $exception =~ /Could not instantiate client for login ID/, 'Expected exception when bogus loginid is supplied';

    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_poa_dates($user), [], 'Undef date would be a delete operation';

    $best_issue_date    = '2020-10-10';
    $best_verified_date = '2021-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_poa_dates($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
            verified_date  => Date::Utility->new($best_verified_date)->date_yyyymmdd,
        }
        ],
        'Insert operation';

    $best_issue_date    = '2023-10-10';
    $best_verified_date = '2024-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_poa_dates($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
            verified_date  => Date::Utility->new($best_verified_date)->date_yyyymmdd,
        }
        ],
        'Update operation';

    $best_verified_date = undef;
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_poa_dates($user), [], 'Delete operation';
};

subtest 'POI updated' => sub {

    sub grab_expiration_date {
        my ($user) = @_;

        return $user->dbic->run(
            fixup => sub {
                $_->selectall_arrayref('SELECT * FROM users.poi_expiration WHERE binary_user_id = ?', {Slice => {}}, $user->id);
            });
    }

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $user = BOM::User->create(
        email          => 'poiexp+test@test.com',
        password       => "hello",
        email_verified => 1,
        email_consent  => 1,
    );

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->save;

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $best_expiration_date;
    $doc_mock->mock(
        'best_expiry_date',
        sub {
            return Date::Utility->new($best_expiration_date) if $best_expiration_date;
            return undef;
        });

    my $exception = exception {
        BOM::Event::Actions::Client::poi_updated({
                loginid => undef,
            })->get;
    };

    ok $exception =~ /No client login ID supplied/, 'Expected exception if no loginid is supplied';

    $exception = exception {
        BOM::Event::Actions::Client::poi_updated({
                loginid => 'CR0',
            })->get;
    };

    ok $exception =~ /Could not instantiate client for login ID/, 'Expected exception when bogus loginid is supplied';

    BOM::Event::Actions::Client::poi_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_expiration_date($user), [], 'Undef date would be a delete operation';

    $best_expiration_date = '2020-10-10';
    BOM::Event::Actions::Client::poi_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_expiration_date($user),
        [{
            binary_user_id         => $user->id,
            last_notification_date => undef,
            expiration_date        => Date::Utility->new($best_expiration_date)->date_yyyymmdd,
        }
        ],
        'Insert operation';

    $best_expiration_date = '2023-10-10';
    BOM::Event::Actions::Client::poi_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_expiration_date($user),
        [{
            binary_user_id         => $user->id,
            last_notification_date => undef,
            expiration_date        => Date::Utility->new($best_expiration_date)->date_yyyymmdd,
        }
        ],
        'Update operation';

    $best_expiration_date = undef;
    BOM::Event::Actions::Client::poi_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_expiration_date($user), [], 'Delete operation';
};

subtest 'underage_client_detected' => sub {
    my $args      = {};
    my $exception = exception {
        BOM::Event::Actions::Client::underage_client_detected($args);
    };

    ok $exception =~ /provider is mandatory/, 'Provider is mandatory to this event';

    $args->{provider} = 'qa';

    $exception = exception {
        BOM::Event::Actions::Client::underage_client_detected($args);
    };

    ok $exception =~ /No client login ID supplied/, 'loginid is mandatory to this event';

    $args->{loginid} = 'CR0';

    $exception = exception {
        BOM::Event::Actions::Client::underage_client_detected($args);
    };

    ok $exception =~ /Could not instantiate client for login ID/, 'legit loginid is mandatory to this event';

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    my $provider;
    my $client_proc;
    my $from_proc;
    my $from;

    my $mock_common = Test::MockModule->new('BOM::Event::Actions::Common');
    $mock_common->mock(
        'handle_under_age_client',
        sub {
            my ($client_proc, $provider, $from_proc) = @_;
            is $client_proc->loginid, $client->loginid, 'Expected client';
            is $provider,             'qa',             'Expected provider';
            ok !$from_proc, 'No from client specified' unless $from;
            is $from_proc->loginid, $from->loginid, 'Expected client' if $from;
            return undef;
        });

    $exception = exception {
        $args->{loginid} = $client->loginid;
        $provider        = undef;
        $client_proc     = undef;
        $from_proc       = undef;
        BOM::Event::Actions::Client::underage_client_detected($args);
    };

    ok !$exception, 'No exception';

    $from = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });

    $exception = exception {
        $provider             = undef;
        $client_proc          = undef;
        $from_proc            = undef;
        $args->{from_loginid} = $from->loginid;
        BOM::Event::Actions::Client::underage_client_detected($args);
    };

    ok !$exception, 'No exception';
    $mock_common->unmock_all;
};

subtest 'timeout simulations' => sub {
    my $module = Test::MockModule->new('BOM::Event::Process');
    $module->mock(
        'actions',
        sub {
            return {
                client_verification => async sub {
                    my ($args) = @_;
                    my $wait = $args->{wait};
                    $args->{loginid} = 'CR9X';    # point of this test is to check if the loginid would get logged on timeout
                    await $loop->delay_future(after => $wait);
                    $log->warn('test did not time out');
                }
            };
        });

    $handler = BOM::Event::QueueHandler->new(
        queue            => 'DOCUMENT_AUTHENTICATION_STREAM',
        maximum_job_time => 0.1,
    );

    subtest 'client verification' => sub {
        $log->clear;
        $loop->add($handler);
        $handler->process_job(
            'DOCUMENT_AUTHENTICATION_STREAM',
            {
                type    => 'client_verification',
                details => {wait => 0.2}})->get;

        $log->contains_ok(qr/CR9X/, 'Loginid did get logged');
    };

    $module->unmock_all;
};

subtest 'onfido api rate limit simulation' => sub {
    my $onfido_mock = Test::MockModule->new('WebService::Async::Onfido');
    $onfido_mock->mock('requests_per_minute', sub { return 1; });
    $onfido_mock->mock('rate_limit_delay',    sub { return 1; });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @doggy_bag;

    $dog_mock->mock(
        'stats_inc',
        sub {
            push @doggy_bag, shift;
        });

    $handler->process_job(
        'DOCUMENT_AUTHENTICATION_STREAM',
        {
            type    => 'client_verification',
            details => {check_url => '/v3.4/checks/mycheckid'}})->get;

    cmp_deeply [@doggy_bag], ['event.onfido.client_verification.dispatch', 'onfido.api.rate_limit'], 'Expected dog bag';

    $dog_mock->unmock_all;
    $onfido_mock->unmock_all;
};

subtest 'onfido check completed' => sub {
    # onfido to the loop
    $loop->add(
        my $onfido = WebService::Async::Onfido->new(
            token    => 'test',
            base_uri => $ENV{ONFIDO_URL}));
    # services to the loop
    $loop->add(my $services = BOM::Event::Services->new);

    my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my @emissions = [];
    $emit_mock->mock(
        'emit',
        sub {
            push @emissions, +{@_};
        });

    # mocks
    my $config_mock = Test::MockModule->new('BOM::Config');
    my $s3_config   = {};
    $config_mock->mock(
        's3',
        sub {
            return {
                document_auth_onfido => $s3_config,
            };
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @dog_bag;
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @dog_bag, @_;
        });
    $dog_mock->mock(
        'stats_timing',
        sub {
            push @dog_bag, @_;
        });

    my $onfido_mock = Test::MockModule->new(ref($onfido));
    my $onfido_future;
    $onfido_mock->mock(
        'download_check',
        sub {
            return $onfido_future if $onfido_future;

            return $onfido_mock->original('download_check')->(@_);
        });

    my $s3_mock = Test::MockModule->new('BOM::Platform::S3Client');
    my $s3_future;
    $s3_mock->mock(
        'upload_binary',
        sub {
            return $s3_future if $s3_future;

            return $s3_mock->original('upload_binary')->(@_);
        });

    my $bom_onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my @updated_checks;
    $bom_onfido_mock->mock(
        'update_check_pdf_status',
        sub {
            push @updated_checks, @_;

            return undef;
        });

    # args for the handler

    my $exception;
    my $args    = {};
    my $handler = BOM::Event::Process->new(category => 'generic')->actions->{onfido_check_completed};

    subtest 'no check id' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        $exception      = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [], 'empty check updates';
        cmp_deeply [@dog_bag],        [], 'empty dog bag';
        cmp_deeply [@emissions],      [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok $exception =~ /No Onfido Check provided/, 'Expected exception';
    };

    subtest 'inexistent check id' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();

        $onfido_future    = Future->fail('404', http => HTTP::Response->new(404, 'Not Found'));
        $args->{check_id} = 'bad-id';
        $exception        = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['bad-id' => 'failed'], 'inexistent id should fail the check on the spot';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.download_error', 'event.onfido.pdf.finish_with_error' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->contains_ok(qr/Onfido http exception with code 404/, 'expected log entry');
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 'Onfido API status 500' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();

        $onfido_future    = Future->fail('500', http => HTTP::Response->new(500, 'Internal Server Error'));
        $args->{check_id} = 'good-id';
        $exception        = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.download_error', 'event.onfido.pdf.finish_with_error' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->contains_ok(qr/Onfido http exception with code 500/, 'expected log entry');
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 'Onfido API status 429' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();

        $onfido_future    = Future->fail('429', http => HTTP::Response->new(429, 'Too Many Requests'));
        $args->{check_id} = 'good-id';
        $exception        = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.download_error', 'event.onfido.pdf.finish_with_error' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->contains_ok(qr/Onfido http exception with code 429/, 'expected log entry');
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload failure (no keys)' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => undef,
            aws_secret_access_key => undef,
            aws_bucket            => undef,
        };

        $onfido_future    = Future->done('PDF');
        $args->{check_id} = 'good-id';
        $exception        = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag], ['event.onfido.pdf.dispatch', 'event.onfido.pdf.s3_error', 'event.onfido.pdf.finish_with_error' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload failure' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->fail('upload failed...');

        $args->{check_id} = 'good-id';
        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag], ['event.onfido.pdf.dispatch', 'event.onfido.pdf.s3_error', 'event.onfido.pdf.finish_with_error' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload success' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('ONFIDO::PDF::LOCK', 0)->get;
        $log->clear();
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id} = 'good-id';
        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['good-id'                                              => 'completed'],       'completed checks';
        cmp_deeply [@dog_bag],        ['event.onfido.pdf.dispatch', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')], 'expected dog calls';
        cmp_deeply [@emissions],      [], 'no emissions';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload success w/ queue size' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('SOME-RANDOM-KEY', 100)->get;
        $redis->del('ONFIDO::PDF::LOCK')->get;

        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id}       = 'good-id';
        $args->{queue_size_key} = 'SOME-RANDOM-KEY';

        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['good-id'                                              => 'completed'],       'completed checks';
        cmp_deeply [@dog_bag],        ['event.onfido.pdf.dispatch', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')], 'expected dog calls';
        cmp_deeply [@emissions],      [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        is $redis->get('SOME-RANDOM-KEY')->get, 99, 'queue decreased by 1';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload success w/ queue size 0' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('SOME-RANDOM-KEY', 0)->get;
        $redis->del('ONFIDO::PDF::LOCK')->get;

        $log->clear();
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id}       = 'good-id';
        $args->{queue_size_key} = 'SOME-RANDOM-KEY';

        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['good-id' => 'completed'], 'completed checks';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.queue_size_underflow', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        is $redis->get('SOME-RANDOM-KEY')->get, 0, 'queue set to 0';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload success w/ queue size < 0' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('SOME-RANDOM-KEY', -1)->get;
        $redis->del('ONFIDO::PDF::LOCK')->get;

        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id}       = 'good-id';
        $args->{queue_size_key} = 'SOME-RANDOM-KEY';

        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['good-id' => 'completed'], 'completed checks';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.queue_size_underflow', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        is $redis->get('SOME-RANDOM-KEY')->get, 0, 'queue set to 0';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 's3 upload success w/ undef queue size' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->del('SOME-RANDOM-KEY')->get;
        $redis->del('ONFIDO::PDF::LOCK')->get;

        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id}       = 'good-id';
        $args->{queue_size_key} = 'SOME-RANDOM-KEY';

        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], ['good-id' => 'completed'], 'completed checks';
        cmp_deeply [@dog_bag],
            ['event.onfido.pdf.dispatch', 'event.onfido.pdf.queue_size_underflow', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')],
            'expected dog calls';
        cmp_deeply [@emissions], [], 'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        is $redis->get('SOME-RANDOM-KEY')->get, 0, 'queue set to 0';
        ok !$redis->get('ONFIDO::PDF::LOCK')->get, 'lock is 0';

        ok !$exception, 'No exception thrown';
    };

    subtest 'redis lock' => sub {
        my $redis = $services->redis_events_write();
        $redis->connect->get;
        $redis->set('SOME-RANDOM-KEY',   1)->get;
        $redis->set('ONFIDO::PDF::LOCK', 1)->get;

        my $redis_mock = Test::MockModule->new(ref($redis));
        my @redis_set;
        $redis_mock->mock(
            'set',
            sub {
                my (undef, @set) = @_;

                push @redis_set, [@set];

                return $redis_mock->original('set')->(@_);
            });

        $log->clear();
        @updated_checks = ();
        @emissions      = ();
        @dog_bag        = ();
        $s3_config      = {
            aws_access_key_id     => 'test',
            aws_secret_access_key => 'test',
            aws_bucket            => 'test',
        };

        $onfido_future = Future->done('PDF');
        $s3_future     = Future->done('test.pdf');

        $args->{check_id}       = 'good-id';
        $args->{queue_size_key} = 'SOME-RANDOM-KEY';

        $exception = exception { $handler->($args)->get };

        cmp_deeply [@updated_checks], [],                                                     'no completed checks';
        cmp_deeply [@dog_bag],        ['event.onfido.pdf.dispatch', 'event.onfido.pdf.busy'], 'expected dog calls';
        cmp_deeply [@emissions],      [],                                                     'no emissions';

        $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
        is $redis->get('SOME-RANDOM-KEY')->get,   1, 'queue stuck at 1';
        is $redis->get('ONFIDO::PDF::LOCK')->get, 1, 'lock stuck at 1';
        cmp_deeply [@redis_set], [[qw/ONFIDO::PDF::LOCK 1 EX 300 NX/]], 'expected redis set call';

        ok !$exception, 'No exception thrown';

        subtest 'unaffected without a queue size key' => sub {
            $redis->set('ONFIDO::PDF::LOCK', 1)->get;
            $log->clear();
            @updated_checks = ();
            @emissions      = ();
            @dog_bag        = ();
            @redis_set      = ();

            delete $args->{queue_size_key};
            $exception = exception { $handler->($args)->get };

            cmp_deeply [@updated_checks], ['good-id'                                              => 'completed'],       'completed checks';
            cmp_deeply [@dog_bag],        ['event.onfido.pdf.dispatch', 'event.onfido.pdf.finish' => re('\d+(\.\d+)?')], 'expected dog calls';
            cmp_deeply [@emissions],      [], 'no emissions';

            $log->does_not_contain_ok(qr/Onfido http exception/, 'no HTTP exception logged');
            is $redis->get('SOME-RANDOM-KEY')->get,   1, 'queue unaffected';
            is $redis->get('ONFIDO::PDF::LOCK')->get, 1, 'lock unaffected';
            cmp_deeply [@redis_set], [], 'expected redis set call';
        };

        $redis_mock->unmock_all;
    };

    $config_mock->unmock_all;
    $dog_mock->unmock_all;
    $s3_mock->unmock_all;
    $onfido_mock->unmock_all;
    $bom_onfido_mock->unmock_all;
};

done_testing();
