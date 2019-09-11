package BOM::Test::RPC::BomRpc;
use strict;
use warnings;

use Mojo::Server::Daemon;
use Path::Tiny;
use BOM::RPC::Transport::HTTP;

my $pid;

BEGIN {
    if (my $rpc_url = $ENV{RPC_URL}) {
        my $config_file = '/tmp/rpc_test.cfg';
        $ENV{RPC_CONFIG} = $config_file;    ## no critic (Variables::RequireLocalizedPunctuationVars)
        path($config_file)->spew(<<EOC);
    app->log(Mojo::Log->new(level => 'debug'));
    app->renderer->default_format('json');
    {
        hypnotoad => {
              listen   => ["$rpc_url"],
              workers  => 10,
              clients  => 1,
              inactivity_timeout => 3600,
              heartbeat_timeout => 120,
              log_detailed_exception => 1
        }
    };
EOC
        $pid = fork;
        if (not defined $pid) {
            die 'Could not fork process to start RPC: ' . $!;
        } elsif ($pid == 0) {
            my $rpc    = BOM::RPC::Transport::HTTP->new();
            my $daemon = Mojo::Server::Daemon->new(
                app    => $rpc,
                listen => [$rpc_url],
            );
            local $SIG{HUP} = sub { $daemon->stop; exit; };
            $daemon->run;
        }
    }
}

END {
    if ($pid) {
        print "Stopping test RPC server ($pid)...\n";
        kill HUP => $pid;
    }
}

1;

