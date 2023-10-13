use strict;
use warnings;

use Test::More;
use Log::Any::Test;
use Log::Any qw($log);
use Test::MockModule;
use Test::Deep;

use BOM::Event::Script::OnfidoPDF;
use IO::Async::Loop;
use BOM::Event::Services;

# Declare here the services we'll be using.

my $loop = IO::Async::Loop->new;
$loop->add(my $services = BOM::Event::Services->new);

my $redis = $services->redis_events_write();

subtest 'batch size' => sub {
    my $checks_per_hour = +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR;

    is(BOM::Event::Script::OnfidoPDF->get_batch_size()->get, $checks_per_hour, 'By default just the constant');

    my $hop = $checks_per_hour / 10 + 1;
    my $i   = 0;
    my $current;

    while (1) {
        $log->clear;

        my $current = BOM::Event::Script::OnfidoPDF->get_batch_size()->get;

        if ($checks_per_hour - $i < 0) {
            is($current, 0, 'cannot drop under 0');

            $log->contains_ok(qr/Onfido PDF downloader:queue size is = 1270, skipping cronjob run/, 'skipping cronjob run, too many messages');
            last;
        }

        is($current, $checks_per_hour - $i, 'Queue increses, room for new checks decreases');

        $i += $hop;
        $redis->set(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE, $i)->get;

        $log->does_not_contain_ok(qr/skipping cronjob run/, 'No logged messages');
    }
};

subtest 'run it' => sub {
    # some mocks to manipulate the function

    my $bom_onfido_mock = Test::MockModule->new('BOM::User::Onfido');
    my @pending_checks;
    $bom_onfido_mock->mock(
        'get_pending_pdf_checks',
        sub {
            return [map { +{id => $_} } @pending_checks];
        });
    my @updated_checks;
    $bom_onfido_mock->mock(
        'update_check_pdf_status',
        sub {
            push @updated_checks, @_;

            return undef;
        });

    my $dog_mock = Test::MockModule->new('DataDog::DogStatsd::Helper');
    my @dog_bag;
    $dog_mock->mock(
        'stats_histogram',
        sub {
            push @dog_bag, @_;
        });
    $dog_mock->mock(
        'stats_inc',
        sub {
            push @dog_bag, @_;
        });

    my $emit_mock = Test::MockModule->new('BOM::Platform::Event::Emitter');
    my @emissions;
    $emit_mock->mock(
        'emit',
        sub {
            push @emissions, @_;
        });

    subtest 'too many messages' => sub {
        # checks
        @pending_checks = ();
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => 0,
            ],
            'Expected dog calls';
        cmp_deeply [@emissions], [], 'No emissions';
        $log->contains_ok(qr/Onfido PDF downloader:queue size is = 1270, skipping cronjob run/, 'No log registered');

        # reset back
        $redis->del(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get;
        is(BOM::Event::Script::OnfidoPDF->get_batch_size()->get, +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR, 'By default just the constant');
    };

    subtest 'nothing in the DB' => sub {
        # checks
        @pending_checks = ();
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR,
            'event.onfido.pdf.fetch_size' => 0,
            ],
            'Expected dog calls';
        cmp_deeply [@emissions], [], 'No emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');
    };

    subtest 'add some checks' => sub {
        # checks
        @pending_checks = map { "t$_" } (1 .. 10);
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR,
            'event.onfido.pdf.fetch_size' => 10,
            map { 'event.onfido.pdf.emit' } (1 .. 10)
            ],
            'Expected dog calls';
        cmp_deeply [@emissions],
            [
            map { ('onfido_check_completed', $_) }
            map { +{check_id => $_, queue_size_key => +BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE,} } @pending_checks
            ],
            'Expected emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, 1, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 10, 'Expected queue size';
    };

    subtest 'add repeated checks' => sub {
        # checks
        @pending_checks = map { "t$_" } (1 .. 10);
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR - 10,
            'event.onfido.pdf.fetch_size' => 10,
            ],
            'Expected dog calls';
        cmp_deeply [@emissions], [], 'No emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, 1, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 10, 'Expected queue size';
    };

    subtest 'mix of new and repeated checks' => sub {
        # checks
        @pending_checks = map { $_ % 2 ? "t$_" : "b$_" } (1 .. 10);
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR - 10,
            'event.onfido.pdf.fetch_size' => 10,
            map { 'event.onfido.pdf.emit' } (1 .. 5)
            ],
            'Expected dog calls';
        cmp_deeply [@emissions],
            [
            map  { ('onfido_check_completed', $_) }
            map  { +{check_id => $_, queue_size_key => +BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE,} }
            grep { $_ =~ /^b/ } @pending_checks
            ],
            'Expected emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, 1, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 15, 'Expected queue size';
    };

    subtest 'mix of new and repeated checks (with lock release)' => sub {
        # checks
        @pending_checks = map { $_ % 2 ? "t$_" : "b$_" } (1 .. 10);
        # release lock
        $redis->del(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get for @pending_checks;
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR - 15,
            'event.onfido.pdf.fetch_size' => 10,
            map { 'event.onfido.pdf.emit' } (1 .. 10)
            ],
            'Expected dog calls';
        cmp_deeply [@emissions],
            [
            map { ('onfido_check_completed', $_) }
            map { +{check_id => $_, queue_size_key => +BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE,} } @pending_checks
            ],
            'Expected emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, 2, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 25, 'Expected queue size';
    };

    subtest 'repeated checks (with lock release)' => sub {
        # checks
        @pending_checks = map { $_ % 2 ? "t$_" : "b$_" } (1 .. 10);
        # release lock
        $redis->del(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get for @pending_checks;
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [], 'no updated checks';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR - 25,
            'event.onfido.pdf.fetch_size' => 10,
            map { 'event.onfido.pdf.emit' } (1 .. 10)
            ],
            'Expected dog calls';
        cmp_deeply [@emissions],
            [
            map { ('onfido_check_completed', $_) }
            map { +{check_id => $_, queue_size_key => +BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE,} } @pending_checks
            ],
            'Expected emissions';
        $log->does_not_contain_ok(qr/Onfido PDF downloader/, 'No log registered');

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, 3, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 35, 'Expected queue size';
    };

    subtest 'repeated checks (with lock release + hitting last attempt)' => sub {
        # checks
        @pending_checks = map { $_ % 2 ? "t$_" : "b$_" } (1 .. 10);
        # release lock
        $redis->del(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get for @pending_checks;
        # cleanup mocks
        @updated_checks = ();
        @dog_bag        = ();
        @emissions      = ();
        #cleanup log
        $log->clear;
        # run it
        BOM::Event::Script::OnfidoPDF->run->get;

        cmp_deeply [@updated_checks], [map { ($_, 'failed') } map { $_ % 2 ? "t$_" : "b$_" } (1 .. 10)], 'expected update check calls';
        cmp_deeply [@dog_bag],
            [
            'event.onfido.pdf.batch_size' => +BOM::Event::Script::OnfidoPDF::CHECKS_PER_HOUR - 35,
            'event.onfido.pdf.fetch_size' => 10,
            map { 'event.onfido.pdf.failed' } (1 .. 10)
            ],
            'Expected dog calls';
        cmp_deeply [@emissions], [], 'No emissions';
        $log->contains_ok(qr/Onfido PDF downloader: giving up on check with id = $_/, 'Giving up is logged') for @pending_checks;

        # redis locked
        ok $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_ENQUEUED . $_)->get, 'Expected redis lock' for @pending_checks;
        # attempts counter
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_CHECK_HITS . $_)->get, undef, 'Expected redis counter' for @pending_checks;
        # queue size
        is $redis->get(+BOM::Event::Script::OnfidoPDF::ONFIDO_PDF_QUEUE_SIZE)->get, 35, 'Expected queue size';
    };
};

done_testing();
