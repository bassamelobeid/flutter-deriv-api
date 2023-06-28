use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::Deep;
use Test::Fatal;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UserTestDatabase qw(:init);

use BOM::Event::Actions::Client;
use BOM::User;
use Date::Utility;
use Future::AsyncAwait;
use Log::Any::Test;
use Log::Any qw($log);

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

    sub grab_issuance_date {
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
        email          => 'error+test@test.com',
        password       => "hello",
        email_verified => 1,
        email_consent  => 1,
    );

    $user->add_client($client);
    $client->binary_user_id($user->id);
    $client->save;

    my $doc_mock = Test::MockModule->new(ref($client->documents));
    my $best_issue_date;
    $doc_mock->mock(
        'best_issue_date',
        sub {
            return Date::Utility->new($best_issue_date) if $best_issue_date;
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

    cmp_deeply grab_issuance_date($user), [], 'Undef date would be a delete operation';

    $best_issue_date = '2020-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
        }
        ],
        'Insert operation';

    $best_issue_date = '2023-10-10';
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user),
        [{
            binary_user_id => $user->id,
            issue_date     => Date::Utility->new($best_issue_date)->date_yyyymmdd,
        }
        ],
        'Update operation';

    $best_issue_date = undef;
    BOM::Event::Actions::Client::poa_updated({
            loginid => $client->loginid,
        })->get;

    cmp_deeply grab_issuance_date($user), [], 'Delete operation';
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

done_testing();
