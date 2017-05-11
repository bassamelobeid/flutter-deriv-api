package BOM::Test::RPC::Service;
use Mojo::Base -base;

use BOM::Test;
use Path::Tiny;
use Net::EmptyPort qw( check_port );
use File::Basename;
use Mojo::URL;

has [qw(url script)];

has name => sub {
    return basename(shift->script);
};

has port => sub {
    return Mojo::URL->new(shift->url)->port;
};

has file_base => sub {
    return '/tmp/' . shift->name;
};
has config_file => sub {
    return shift->file_base . '.cfg';
};

has pid_file => sub {
    return shift->file_base . '.pid';
};

has log_file => sub {
    return shift->file_base . '.log';
};

has config => sub {
    my $self = shift;
    my ($log_file, $url, $pid_file) = ($self->log_file, $self->url, $self->pid_file);
    return <<EOC;
  app->log(Mojo::Log->new(
                            level => 'info',
                            path  => '$log_file'
                           ));
  app->renderer->default_format('json');

  {
    hypnotoad => {
                  listen   => ["$url"],
                  workers  => 10,
                  clients  => 1,
                  pid_file => '$pid_file',
                  inactivity_timeout => 3600,
                  heartbeat_timeout => 120,
                 }
  };
EOC
};

sub start_rpc_if_not_running {
    my $self = shift;
    return unless $self->url;
    return check_port($self->port) || $self->start_rpc();
}

sub start_rpc {
    my $self        = shift;
    my $config_file = $self->config_file;
    my $script      = $self->script;
    path($config_file)->spew($self->config);

    my $pid = fork;
    if (not defined $pid) {
        die 'Could not fork process to start pricing service: ' . $!;
    } elsif ($pid == 0) {
        exec "/usr/bin/env RPC_CONFIG=$config_file perl -MBOM::Test -MBOM::Test::Time /home/git/regentmarkets/cpan/local/bin/hypnotoad $script";
        die "Oops... Couldn't start pricing service: $!, please see log file " . $self->log_file;
    }
    waitpid($pid, 0);
    unless (Net::EmptyPort::wait_port($self->port, 20)) {
        my $error = "Pricing service still not ready, what happened?\n";

        #when run test with prove, 'die' cannot display the error message
        #So I print this error before die.
        print STDERR $error;
        die $error;
    }

    return;

}

sub stop_rpc {
    my $self = shift;
    return unless $self->url;
    my $pfile = path($self->pid_file);

    if ($pfile->exists) {
        chomp(my $pid = $pfile->slurp);
        if (kill(0, $pid)) {
            my $cmd  = path("/proc/$pid/cmdline")->slurp;
            my $name = $self->name;
            kill 'SIGTERM', $pid if $cmd =~ /$name/;
            wait_till_exit($pid, 10);
        }
        unlink $self->config_file;
    }
    return;
}

sub wait_till_exit {
    my ($pid, $timeout) = @_;
    my $start = time;
    while (time - $start < $timeout and kill ZERO => $pid) {
        print "wait $pid...\n";
        sleep 1;
    }
    return;
}

1;
