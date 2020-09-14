#!/usr/bin/env perl
use strict;
use warnings;
no indirect;

no indirect;
use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;
use LandingCompany::Registry;
use BOM::Database::ClientDB;
use Time::HiRes;
use Getopt::Long;
use Log::Any qw($log);
use List::Util qw(uniq);
use Syntax::Keyword::Try;

use BOM::Config::Runtime;
use BOM::Platform::Context qw(request);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions('l|log=s' => \my $log_level) or die;

$log_level ||= 'info';

Log::Any::Adapter->import(qw(Stderr), log_level => $log_level);

=head1 Name

p2p_daemon - the daemon process operations which should happen at some particular.

=head1 Description

The Daemon checks database every established interval of time C<POLLING_INTERVAL> and
emits event for every order/advert, which state need to be updated.

=cut

# Seconds between each attempt at checking the database entries.
use constant POLLING_INTERVAL => 60;

# request brand name should be changed to 'deriv', otherwise the event will not be sent to Segment.
request(BOM::Platform::Context::Request->new(
    brand_name => 'deriv'
));

my @broker_codes = uniq map { $_->{broker_codes}->@* } grep { $_->{p2p_available} } values LandingCompany::Registry::get_loaded_landing_companies()->%*;
my $app_config = BOM::Config::Runtime->instance->app_config;
my $loop     = IO::Async::Loop->new;
my $shutdown = $loop->new_future;
$shutdown->on_ready(sub {
    $log->info('Shut down');
});

my $signal_handler = sub {$shutdown->done};
$loop->watch_signal(INT  => $signal_handler);
$loop->watch_signal(TERM => $signal_handler);

my %dbs;
(async sub {
    $log->info('Starting P2P polling');
    until ($shutdown->is_ready) {
        $app_config->check_for_update;
        for my $broker (@broker_codes) {
            try {
                $dbs{$broker} //= BOM::Database::ClientDB->new({broker_code => $broker})->db->dbh;
            }
            catch {
                $log->warnf('Fail to connect to client db %s: %s', $broker, $@);
            }
            next unless $dbs{$broker};
            # Stopquering db when feature is disabled
            last if $app_config->system->suspend->p2p || !$app_config->payments->p2p->enabled;
            $log->debug('P2P: Checking for expired orders');
            try {
                my $sth = $dbs{$broker}->prepare('SELECT id, client_loginid FROM p2p.order_list_expired() WHERE status IN (?,?)');
                # Seems a waste to fetch and send `timed-out` orders through the events queue just to be discarded by `bom-users`
                $sth->execute(qw(pending buyer-confirmed));
                
                while (my $order_data = $sth->fetchrow_hashref) {
                    $log->debugf('P2P: Emitting event to mark order as expired for order %s', $order_data->{id});

                    BOM::Platform::Event::Emitter::emit(
                        p2p_order_expired => {
                            client_loginid => $order_data->{client_loginid},
                            order_id       => $order_data->{id},
                            expiry_started => [Time::HiRes::gettimeofday],
                        });
                }
                $sth->finish;
            }
            catch ($error) {
                $log->warnf('Failed to get expired P2P orders from client db %s: %s', $broker, $error);
                delete $dbs{$broker};
            }
            next unless $dbs{$broker};
            $log->debug('P2P: Checking for ready to refund orders');
            try {
                # The days needed to reach the refund are dynamically configured (default 30 days)
                my $days_to_refund = $app_config->payments->p2p->refund_timeout;
                my $sth = $dbs{$broker}->prepare('SELECT id, client_loginid FROM p2p.order_list_refundable(?)');
                $sth->execute($days_to_refund);

                while (my $order_data = $sth->fetchrow_hashref) {
                    $log->debugf('P2P: Emitting event to move funds back, order %s', $order_data->{id});
                    BOM::Platform::Event::Emitter::emit(
                        p2p_timeout_refund => {
                            client_loginid => $order_data->{client_loginid},
                            order_id       => $order_data->{id},
                        });
                }
            }
            catch ($error) {
                $log->warnf('Failed to get expired P2P orders from client db %s: %s', $broker, $error);
                delete $dbs{$broker};
            }
        }

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown->without_cancel);
    }
})->()->get;
