package BOM::Test::Rpc;

use strict;
use warnings;

use BOM::Test;
use Path::Tiny;
use Net::EmptyPort qw( check_port );
use Time::HiRes qw( usleep );

sub config {
    return {} unless $ENV{RPC_URL};
    my $port = (split /:/, $ENV{RPC_URL})[-1];
    $port =~ s{/}{}g;
    my $cfg = {
        url         => $ENV{RPC_URL},
        port        => $port,
        config_file => '/tmp/rpc.cfg',
        pid_file    => '/tmp/bom-rpc.pid',
        log_file    => '/tmp/bom-rpc_trace.log',
    };
    my $config = <<EOC;
  app->log(Mojo::Log->new(
                            level => 'info',
                            path  => '$log_file'
                           ));
  app->renderer->default_format('json');

  {
    hypnotoad => {
                  listen   => ["$cfg->{url}"],
                  workers  => 10,
                  pid_file => '$cfg->{pid_file}',
                  user     => 'nobody',
                  group    => 'nogroup',
                  inactivity_timeout => 3600,
                  heartbeat_timeout => 120,
                 }
  };
EOC

    $cfg->{config} = $config;
    return $cfg;
}

sub start_rpc_if_not_running {
    my $cfg = config();
    return unless $cfg->{url};
    return check_port($cfg->{port}) || start_rpc();
}

sub start_rpc {
    my $cfg = config();
    path($cfg->{config_file})->spew($cfg->{config});

    my $pid = fork;
    if (not defined $pid) {
        die 'Could not fork process to start rpc service: ' . $!;
    } elsif ($pid == 0) {
        exec
            "/usr/bin/env RPC_CONFIG=$cfg->{config_file} perl -MBOM::Test /home/git/regentmarkets/bom-rpc/bin/binary_rpc.pl daemon -m production -l $cfg->{url}jsonrpc";
        die "Oops... Couldn't start rpc service: $!, please see log file $cfg->{log_file}";
    }

    unless (Net::EmptyPort::wait_port($cfg->{port}, 10)) {
        die "Rpc service still not ready, what happened?\n";
    }

    path($cfg->{pid_file})->spew($pid);

    return;

}

sub stop_rpc {
    my $cfg = config();
    return unless $cfg->{url};
    my $pfile = path($cfg->{pid_file});

    if ($pfile->exists) {
        chomp(my $pid = $pfile->slurp);
        if (kill(0, $pid)) {
            my $cmd = path("/proc/$pid/cmdline")->slurp;
            kill 9, $pid if $cmd =~ /rpc/;
            wait_till_exit($pid, 3);
        }
        if (kill(0, $pid)) {
            die "cannot stop rpc service!";
        } else {
            unlink($cfg->{pid_file});
            unlink $cfg->{config_file};
        }
    }
    return;
}

sub wait_till_exit {
    my ($pid, $timeout) = @_;
    my $start = time;
    while ((time - $start < $timeout) and kill ZERO => $pid) {
        usleep 1e5;
    }
    return;
}

BEGIN {
    start_rpc_if_not_running();
}

END {
    stop_rpc();
}

1;
