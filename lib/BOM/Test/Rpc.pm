package BOM::Test::Rpc;

use strict;
use warnings;

use BOM::Test;
use Path::Tiny;
use Net::EmptyPort qw( check_port );
use Time::HiRes qw( usleep );

BEGIN {
  start_rpc_if_not_running();
}

sub start_rpc_if_not_running{
  return unless $ENV{RPC_URL};
  my $rpc_port = (split /:/, $ENV{RPC_URL})[-1];
  return check_port($rpc_port) || restart_rpc();
}

sub restart_rpc{
  my $rpc_url = $ENV{RPC_URL};
  my $config = <<EOC
    app->log(Mojo::Log->new(
                            level => 'info',
                            path  => '/var/log/httpd/bom-rpc_trace.log'
                           ));
  app->renderer->default_format('json');

  {
    hypnotoad => {
                  listen   => ["$rpc_url"],
                  workers  => 10,
                  pid_file => '/var/run/bom-daemon/bom-rpc.pid',
                  user     => 'nobody',
                  group    => 'nogroup',
                  inactivity_timeout => 3600,
                  heartbeat_timeout => 120,
                 }
  };
EOC

print $config;
}
