package BOM::Test::Pricing;

use strict;
use warnings;

use BOM::Test;
use Path::Tiny;
use Net::EmptyPort qw( check_port );
use Time::HiRes qw( usleep );

sub config {
    return {} unless $ENV{PRICING_RPC_URL};
    my $port = (split /:/, $ENV{PRICING_RPC_URL})[-1];
    $port =~ s{/}{}g;
    my $cfg = {
        url         => $ENV{PRICING_RPC_URL},
        port        => $port,
        config_file => '/tmp/pricing.cfg',
        pid_file    => '/tmp/bom-pricing.pid',
        log_file    => '/tmp/bom-pricing_trace.log',
    };
    my $config = <<EOC;
  app->log(Mojo::Log->new(
                            level => 'info',
                            path  => '$cfg->{log_file}'
                           ));
  app->renderer->default_format('json');

  {
    hypnotoad => {
                  listen   => ["$cfg->{url}"],
                  workers  => 10,
                  clients  => 1,
                  pid_file => '$cfg->{pid_file}',
                  inactivity_timeout => 3600,
                  heartbeat_timeout => 120,
                 }
  };
EOC

    $cfg->{config} = $config;
    return $cfg;
}

sub start_pricing_if_not_running {
    my $cfg = config();
    return unless $cfg->{url};
    return check_port($cfg->{port}) || start_pricing();
}

sub start_pricing {
    my $cfg = config();
    path($cfg->{config_file})->spew($cfg->{config});

    my $pid = fork;
    if (not defined $pid) {
        die 'Could not fork process to start pricing service: ' . $!;
    } elsif ($pid == 0) {
        exec
            "/usr/bin/env RPC_CONFIG=$cfg->{config_file} perl -MBOM::Test /home/git/regentmarkets/cpan/local/bin/hypnotoad /home/git/regentmarkets/bom-pricing/bin/binary_pricing_rpc.pl";
        die "Oops... Couldn't start pricing service: $!, please see log file $cfg->{log_file}";
    }
    waitpid($pid, 0);
    unless (Net::EmptyPort::wait_port($cfg->{port}, 20)) {
        my $error = "Pricing service still not ready, what happened?\n";
        #when run test with prove, 'die' cannot display the error message
        #So I print this error before die.
        print STDERR $error;
        die $error;
    }

    return;

}

sub stop_pricing {
    my $cfg = config();
    return unless $cfg->{url};
    my $pfile = path($cfg->{pid_file});

    if ($pfile->exists) {
        chomp(my $pid = $pfile->slurp);
        if (kill(0, $pid)) {
            my $cmd = path("/proc/$pid/cmdline")->slurp;
            kill 'SIGTERM', $pid if $cmd =~ /pricing/;
            wait_till_exit($pid, 10);
        }
        unlink $cfg->{config_file};
    }
    return;
}

sub wait_till_exit {
    my ($pid, $timeout) = @_;
    my $start = time;
    while (time - $start < $timeout and kill ZERO => $pid) {
        #usleep 1e5;
        print "wait $pid...\n";
        sleep 1;
    }
    return;
}

BEGIN {
    start_pricing_if_not_running();
}

END {
    stop_pricing();
}

1;
