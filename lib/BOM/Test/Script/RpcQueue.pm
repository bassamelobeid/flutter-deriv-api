package BOM::Test::Script::RpcQueue;
use strict;
use warnings;

use BOM::Test;
use BOM::Test::Script;

sub create_path {
    my $path = shift;
    use Path::Tiny;
    return if path($path)->exists;
    system("sudo mkdir $path");
    warn "FAILED TO CREATE PATH $path" if $?;
}

sub new {
    my ($class, $redis_server) = @_;

    my $socket = '/tmp/binary_jobqueue_worker.sock';
    $redis_server->url =~ /.*:(\d+)\D?$/;
    my $url = 'redis://127.0.0.1:' . $1;

    my $script;
    if (BOM::Test::on_qa) {
        $script = BOM::Test::Script->new(
            script => "/home/git/regentmarkets/bom-rpc/bin/binary_jobqueue_worker.pl",
            args   => "--testing --workers 1 --redis $url --socket $socket",
        );
        create_path('/var/run/bom-rpc/');
        system('sudo chown nobody /var/run/bom-rpc');
        warn "FAILED TO SET OWNER" if $?;
        system('sudo chmod 770 /var/run/bom-rpc');
        warn "FAILED TO SET MODE" if $?;
        $script->stop_script;
        $script->start_script_if_not_running;
        warn 'RPC QUEUE IS NOT LOADED' unless $script->check_script;
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

