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

# For now keeping it here,
# When decided to add new companies better to move it to dynamic configuration.
use constant ACTIVE_LANDING_COMPANIES => ['svg'];

my @broker_codes = uniq map { LandingCompany::Registry::get($_)->broker_codes->@* } @{ACTIVE_LANDING_COMPANIES()};
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
                my $sth = $dbs{$broker}->prepare('SELECT id, client_loginid FROM p2p.order_list_expired()');
                $sth->execute();
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
            catch {
                $log->warnf('Fail to get expired orders from client db %s: %s', $broker, $@);
                delete $dbs{$broker};
            }
        }

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown->without_cancel);
    }
})->()->get;
