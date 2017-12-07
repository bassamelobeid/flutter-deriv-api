package Binary::ContractFuture;

use strict;
use warnings;
use Binary::WebSocketAPI::v3::Wrapper::Pricer;
use Encode;
use Future::Mojo;
use JSON::MaybeXS;
use List::UtilsBy;
use Mojo::Redis2;
use Mojo::URL;
use Scalar::Util qw/ refaddr /;
use YAML::XS qw/LoadFile/;

use constant PRICING_TIMEOUT => 10;

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
            $msg = JSON::MaybeXS->new->decode(Encode::decode_utf8($msg));

            for my $f (map { $_->[1] } @{$subscribers->{$channel} || []}) {
                # Might be cancelled if the client disconnected
                $f->done($msg) unless $f->is_ready;
            }

        });
    $redis->on(error => sub { my ($self, $err) = @_; warn $err; });

    return $redis;
}

sub _clear {
    my $channel = shift;
    my $f       = shift;
    my $refaddr = refaddr($f);
    List::UtilsBy::extract_by { refaddr($_->[1]) == $refaddr } @{$subscribers->{$channel}}
        or warn "ContractFuture::_clear future was not found";

    # unsubscribe when there are no requests anymore
    if (not @{$subscribers->{$channel}}) {
        $redis->unsubscribe($channel);
        delete $subscribers->{$channel};
    }
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

    my $channel = Binary::WebSocketAPI::v3::Wrapper::Pricer::_serialized_args($args, {keep_language => 1});
    if (not $subscribers->{$channel}) {
        $redis->subscribe(
            [$channel],
            sub {
                my ($self, $err) = @_;
                if ($err) {
                    warn $err;
                    return;
                }
                $redis->publish('high_priority_prices', $channel);
            });
    }
    my $f = Future::Mojo->new;
    my $combined_future =
        Future->wait_any(Future::Mojo->new_timer(PRICING_TIMEOUT)->then(sub { Future->fail('Timeout') }), $f)
        ->on_ready(sub { _clear($channel, $f); })->on_cancel(sub { $f->cancel unless $f->is_ready });
    push @{$subscribers->{$channel}}, [$combined_future, $f];

    return $combined_future;
}

sub get {
    my $f = Binary::ContractFuture::pricing_future(@_);
    return $f->get;
}

1;
