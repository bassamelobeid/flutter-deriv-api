package Binary::WebSocketAPI::BalanceConnections;

use strict;
use warnings;

# The purpose of this module is to Mojo::IOLoop::Server::_accept().
# It should be loaded early on by Binary::WebSocketAPI.

# The problem with the default Mojolicious implementation is that
# it does not allow for more or less equal load distribution among
# the prefork worker processes. This is usually not a problem for
# pure web servers but if the server mainly handles websocket
# connections, having most of them connected to the same process
# is bad.

# In the original code, whenever the listening handle becomes available,
# a loop is started to accept all connection requests. With websockets
# connection requests are rare and connections are long-lived. Also,
# processes handling these connections should be mostly in an idle state
# where they are able to react on incoming traffic. This leads now to
# the following situation. Several processes are waiting to accept
# connections. When a request comes in all of them are woken up and
# race to accept it. Unfortunately Linux does not wake them up in random
# order but in LIFO. So, the last process that entered the wait queue
# is woken up first. Usually it succeeds to accept the connection.
# But this process takes a longer time than simply failing to accept.
# So, normally all the other processes will have queued up again when
# the process that accepted the connection enters the queue. That way
# that process becomes the first to be woken up for the next connection
# request. This proceeds until this process becomes slightly overloaded.

# The idea to solve this problem is to delay accepting the connection
# request a tiny random bit. This re-shuffles the queue. Since
# connection requests are rare, this additional delay should not matter
# at all.

# In addition to solving he main problem this module also pushes
# information about the current number of connections to datadog
# and provides a function to classify the current connection count.
# The result of this function is supposed to be used as a tag sent
# with other metrics to datadog.

use Mojo::IOLoop::Server ();
use DataDog::DogStatsd::Helper qw/stats_histogram/;
use Socket qw/IPPROTO_TCP TCP_NODELAY/;
use Scalar::Util qw/weaken/;

my $active_connections = 0;
my $timer_set;

sub connection_count_class {
    if ($active_connections < 20) {
        return 'lt20';
    } elsif ($active_connections < 50) {
        return 'lt50';
    } elsif ($active_connections < 100) {
        return 'lt100';
    } elsif ($active_connections < 200) {
        return 'lt200';
    } elsif ($active_connections < 300) {
        return 'lt300';
    } elsif ($active_connections < 400) {
        return 'lt400';
    } elsif ($active_connections < 500) {
        return 'lt500';
    } else {
        return 'ge500';
    }
}

sub G::DESTROY {
    my $self = shift;
    return $self->();
}

my $my_accept = sub {
    my $self = shift;

    return unless $self->{active};

    unless ($timer_set) {
        $timer_set = 1;
        $self->reactor->recurring(
            10,
            sub {
                stats_histogram 'bom_websocket_api.ws_connection_count', $active_connections;
            });
    }

    weaken $self;
    my $acc = sub {
        return 0 unless $self;
        my $handle = $self->{handle}->accept;
        unless ($handle) {
            # turn it back on
            $self->reactor->io($self->{handle} => sub { $self->_accept });
            return 0;
        }
        $active_connections++;
        ${*$handle}{__G__} = bless sub {
            $active_connections--;
        }, 'G';
        $handle->blocking(0);

        # Disable Nagle's algorithm
        setsockopt $handle, IPPROTO_TCP, TCP_NODELAY, 1;

        my $args = $self->{args};
        $self->emit(accept => $handle) and return 1 unless $args->{tls};

        # Start TLS handshake
        my $tls = Mojo::IOLoop::TLS->new($handle)->reactor($self->reactor);
        $tls->on(upgrade => sub { $self->emit(accept => pop) });
        $tls->on(error => sub { });
        $tls->negotiate(%$args, server => 1);
        return 1;
    };
    if ($self->{args}->{single_accept}) {
        $acc->();
        return;
    }

    $self->reactor->remove($self->{handle});    # turn it off temporarily
    my $tm;
    $tm = sub {
        # we rely on Mojo::Server::Prefork::_spawn calling srand() here
        $self->reactor->timer(
            0.02 + rand(0.08),
            sub {
                $tm->() if $self->{active} and $acc->();
            });
    };
    $tm->();
};

{
    no warnings 'redefine';    ## no critic
    *Mojo::IOLoop::Server::_accept = $my_accept;
}

1;
