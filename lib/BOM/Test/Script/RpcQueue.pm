package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

sub new {
    my ($class, $port) = @_;
    my $script;
    if (BOM::Test::on_qa()) {
        $script = BOM::Test::Script->new(
            script => "/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl",
            args   => "--port $port"
        );
        $script->start_script_if_not_running;
    }
    return bless {
        port   => $port,
        script => $script
    }, $class;
}

sub DESTROY {
    my $self = shift;

    if ($self->script) {
        $self->script->stop_script;
    }
}

1;

