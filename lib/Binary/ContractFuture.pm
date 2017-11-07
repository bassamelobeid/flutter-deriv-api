package Binary::ContractFuture;

use strict;
use warnings;
use Future::Mojo;
use JSON::MaybeXS;
use Mojo::URL;
use YAML::XS qw/LoadFile/;

use constant PRICING_TIMEOUT => 3;

my $subscribers = {};

my $cf = LoadFile($ENV{BOM_TEST_REDIS_REPLICATED} // '/etc/rmg/redis-pricer.yml')->{write};

my $redis = _connect();

sub _connect {
    my $redis_url = Mojo::URL->new("redis://$cf->{host}:$cf->{port}");

    $redis_url->userinfo('dummy:' . $cf->{password}) if $cf->{password};
    my $redis = Mojo::Redis2->new(url => $redis_url);
    $redis->on(
        message => sub {
            my ($self, $msg, $channel) = @_;
            $msg = JSON::MaybeXS->new->decode($msg);

            for (@{$subscribers->{$channel}}) {
                $_->[1]->done($msg);
            }

        });
    return $redis;
}

sub _clear {
    my $channel = shift;
    $redis->unsubscribe($channel);
    #XXX: remove specific future instead of all?
    delete $subscribers->{$channel};
    return;
}

=head2 pricing_future

 Returns a future which will be resolved on contract is priced.
 Future is saved and deleted when needed in this module.

=cut

sub pricing_future {
    my ($args) = shift;
    $args->{price_daemon_cmd} //= 'price';
    $args->{language}         //= 'EN';

    my $channel = Binary::WebSocketAPI::v3::Wrapper::Pricer::_serialized_args($args);
    $redis->subscribe([$channel]);
    $redis->publish('high_priority_prices', $channel);

    my $f = Future::Mojo->new;
    my $combined_future =
        Future->wait_any(Future::Mojo->new_timer(PRICING_TIMEOUT)->then(sub { Future->fail('Timeout') }), $f);
    $combined_future->on_ready(sub { _clear($channel); });
    push @{$subscribers->{$channel}}, [$combined_future, $f];

    return $combined_future;
}

sub get {
    my $f = Binary::ContractFuture::pricing_future(@_);
    return $f->get;
}

1;
