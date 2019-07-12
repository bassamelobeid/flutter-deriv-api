package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

sub new {
    my ($class, $redis_server) = @_;
    my $script;
    my $socket = '/tmp/binary_jobqueue_worker.sock';
    my $url    = $redis_server->url;
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(
            script => "/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl",
            args   => "--redis $url --socket $socket",
        );
        $script->start_script_if_not_running;
    }
    return bless {
        redis  => $redis_server,
        script => $script,
        socket => $socket,
    }, $class;
}

sub DESTROY {
    my $self = shift;

    if ($self->{script}) {
        $self->{script}->stop_script;
    }
    return;
}

1;

