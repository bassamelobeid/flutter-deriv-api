#!/usr/bin/env perl 
use strict;
use warnings;

no indirect;
use IO::Async::Loop;
use Future::AsyncAwait;
use BOM::Platform::Event::Emitter;
use LandingCompany::Registry;
use BOM::Database::ClientDB;
use BOM::Config::Runtime;

use DataDog::DogStatsd::Helper qw(stats_inc);

use Log::Any qw($log);

=head1 Name

p2p_daemon - the daemon process operations which should happen at some particular.

=head1 Description

The Daemon checks database every established interval of time C<POLLING_INTERVAL> and
emits event for every order/offer, which state need to be updated.

=cut

# Seconds between each attempt at checking the database entries.
use constant POLLING_INTERVAL => 60;

# For now keeping it here,
# When decided to add new companies better to move it to dynamic configuration.
use constant ACTIVE_LANDING_COMPANIES => ['svg'];

my @dbs;
for my $landing_company (@{ ACTIVE_LANDING_COMPANIES() }) {
    my @broker_codes = LandingCompany::Registry::get($landing_company)->broker_codes->@*;
    for my $broker_code (@broker_codes) {
        push @dbs, BOM::Database::ClientDB->new({broker_code => $broker_code});
    }
}


my $app_config = BOM::Config::Runtime->instance->app_config;

my $loop = IO::Async::Loop->new;
my $shutdown = $loop->new_future;
$shutdown->on_ready(sub {
    $log->infof('Shut down');
});
$loop->watch_signal(INT => sub {
    $shutdown->done;
});

$log->infof('Starting P2P polling');

(async sub {
    $log->infof('Starting P2P polling');
    until($shutdown->is_ready) {
        for my $cur_db ( @dbs ) {
            # Stop quering db when feature is disabled
            last if $app_config->system->suspend->p2p || !$app_config->payments->p2p->enabled;
            my $sth = $cur_db->db->dbh->prepare('SELECT id FROM p2p.order_list_expired()');
            $sth->execute();

            while ( my $order_data = $sth->fetchrow_hashref ) {
                stats_inc('p2p.order.expired');
                BOM::Platform::Event::Emitter::emit(
                    p2p_order_expired => {
                        broker_code => $cur_db->broker_code,
                        loginid     => $order_data->{client_loginid},
                        order_id    => $order_data->{id},
                    }
                );
            }
            $sth->finish;
        }

        await Future->wait_any(
            $loop->delay_future(after => POLLING_INTERVAL),
            $shutdown->without_cancel);
    }
})->()->get;
