use Test::Most;
use Test::MockObject;
use JSON::MaybeUTF8 qw(:v1);
use Binary::WebSocketAPI::Plugins::Longcode;

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',    sub { return shift->{stash} });
    $c->mock('tx',       sub { return 1 });
    $c->mock('finish',   sub { my $self = shift; $self->{stash} = {} });
    $c->mock('call_rpc', sub { shift;            return shift; });

    return $c;
}

my $c = mock_c();

my $plugin = new_ok('Binary::WebSocketAPI::Plugins::Longcode' => []);

is $plugin->memory_cache_key('USD', 'en', 'cr'), "USD\0en\0cr", 'memory_cache_key matches';

is $plugin->pending_request_key('USD', 'en'), "USD\0en", 'pending_request_key matches';

isa_ok $plugin->longcode($c, 'cr', 'USD'), 'Future::Mojo', 'longcode';

done_testing();
