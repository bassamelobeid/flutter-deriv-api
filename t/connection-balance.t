use strict;
use warnings;

use Test::More;
use Test::MemoryGrowth;
use Syntax::Keyword::Try;

# Due to a *different* memory leak in the Mojo::Reactor timer
# handling, we have to switch out the reactor to a simpler one
# to cover the specific leak in *our* code
BEGIN { $ENV{MOJO_REACTOR} = 'Mojo::Reactor::Poll' }

use Binary::WebSocketAPI::BalanceConnections;

use Mojo::IOLoop::Server;
use Scalar::Util qw(refaddr weaken);

use Variable::Disposition qw(dispose);

my $connection_accepted = 0;

# Create listen socket
my $server = Mojo::IOLoop::Server->new;
$server->on(accept => sub {
	my ($server, $handle) = @_;
    ++$connection_accepted;
});
$server->listen(port => 0);

# Start and stop accepting connections
$server->start;
my $port = $server->port;

my $connection_success = 0;
my $connection_failure = 0;
my $connection_attempt = 0;

# Hold on to clients until they connect or fail
my $clients = 0;
Mojo::IOLoop->recurring(0.0001 => sub {
    try {
        return if $clients > 1000;
        my $client = Mojo::IOLoop::Client->new;
        $client->on(connect => sub {
            my (undef, $handle) = @_;
            ++$connection_success;
            $handle->close;
            $client->_cleanup;
            weaken $client;
            --$clients;
        });
        ++$clients;
        $client->connect(port => $port);
        ++$connection_attempt;
    } catch {
        fail("exception - $@");
    }
});

# Run for a few seconds
no_growth {
    # Alternatively, run this:
    # Mojo::IOLoop->one_tick
    # for many more iterations and that'll make the `pmat-diff` output more useful
    Mojo::IOLoop->timer(0.1 => sub {
        $server->reactor->stop;
    });
    $server->reactor->start unless $server->reactor->is_running;
} calls => 20, burn_in => 10, 'loop does not leak memory';

cmp_ok($connection_success, '>', 100, 'have a few connection successes');
cmp_ok($connection_attempt, '>=', $connection_success, 'only succeeded at most as many times as we tried');
ok(!$connection_failure, 'no failures');
done_testing;

