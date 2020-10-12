package BOM::Test::RPC::BinaryRpcMojo;

use strict;
use warnings;

use Mojo::Server::Daemon;
use Path::Tiny;

my $pid;

BEGIN {
    # BOM::Test is needed to load $ENV{RPC_URL}
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
    my $rpc_url = $ENV{RPC_URL};

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
        local $ENV{NO_PURGE_REDIS} = 1;
        # TODO run /home/git/regentmarkets/bom-rpc/bin/binary_rpc.pl directly
        my $script = '/home/git/regentmarkets/bom-test/bin/binary_rpc_for_test.pl';

        exec($^X, qw(-MBOM::Test), $script) or die "Couldn't $script: $!";
    }
    # it will cause the test bom-websocket-tests/v3/misc/02_website_status.t to fail if it is not ready before starting test.
    # so let's waiting bom-rpc ready
    # TODO find a better way to check its status
    sleep 5;

}

END {
    if ($pid) {
        print "Stopping test RPC server ($pid)...\n";
        kill HUP => $pid;
    }
}

1;

