use Test::Most;
use Test::MockObject;

use Binary::WebSocketAPI::Hooks;

use Data::Dumper;

sub mock_c {
    my $c = Test::MockObject->new;
    $c->{stash} = {};
    $c->mock('stash',  sub { shift; my $key = shift; return $c->{stash}->{$key} if 1 > @_; $c->{stash}->{$key} = shift; });
    $c->mock('send',   sub { shift; $c->{send_data}   = shift; });
    $c->mock('finish', sub { shift; $c->{finish_data} = [@_]; });
    return $c;
}

subtest 'after_dispatch hook' => sub {
    my $c = mock_c();

    Binary::WebSocketAPI::Hooks::after_dispatch($c);
    is $c->{finish_data}, undef, 'finish was nto called';

    $c->stash('disconnect' => [1013 => 'Service Unavailable']);
    Binary::WebSocketAPI::Hooks::after_dispatch($c);
    is_deeply $c->{finish_data}, [1013 => 'Service Unavailable'], 'finish was called to close the connection';
};

done_testing;

