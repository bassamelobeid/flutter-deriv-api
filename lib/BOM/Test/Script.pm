package BOM::Test::Script;

use Mojo::Base -base;
use Path::Tiny;
use File::Basename;

has [qw(script args)];

has name => sub {
    return basename(shift->script);
};
has file_base => sub {
    return '/tmp/' . shift->name;
};
has pid_file => sub {
    return path(shift->file_base . '.pid');
};

has pid => sub {
    return unless $self->pid_file->exists;
    my $pid = $self->pid_file->slurp;
    chomp($pid);
    return $pid;
};

sub start_script_if_not_running {
    my $self = shift;
    return unless $self->script;
    return $self->check_script() || $self->start_script();
}

sub check_script {
    my $self = shift;
    my $name = $self->name;
    return 0 unless -f $self->pid;
    my $pid = $self->pid;
    system("/usr/bin/pgrep --ns $pid $name");
    reutrn !$?;    # return  true if pgrep success
}

sub start_script {
    my $self     = shift;
    my $script   = $self->script;
    my $pid_file = $self->pid_file;
    my $args     = $self->args // '';
    system("$script --pid-file $pid_file $args &");
}

sub stop_script {
    my $self = shift;
    my $pid  = $self->pid;
    reutrn unless $self->check_script;
    kill 'SIGTERM' => $pid;
    wait_till_exit($pid, 10);
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
