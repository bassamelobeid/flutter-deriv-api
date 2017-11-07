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

sub pid {
    my $self = shift;
    return unless $self->pid_file->exists;
    my $pid = $self->pid_file->slurp;
    chomp($pid);
    return $pid;
}

sub check_script {
    my $self = shift;
    my $pid  = $self->pid;
    return 0 unless $pid;
    my $name = $self->name;
    local $?;    # localise $? in case this method is called at END time
    system("/usr/bin/pgrep -f $name | grep $pid");
    return !$?;    # return  true if pgrep success
}

sub start_script_if_not_running {
    my $self = shift;
    return unless $self->script;
    return $self->check_script() || $self->start_script();
}

sub start_script {
    my $self   = shift;
    my $script = $self->script;
    return unless $script;
    my $pid_file = $self->pid_file;
    $pid_file->remove;
    my $args = $self->args // '';
    system("$script --pid-file $pid_file $args &");
    for (1 .. 5) {
        last if $pid_file->exists;
        sleep 1;
    }
    return;
}

sub stop_script {
    my $self = shift;
    my $pid  = $self->pid;
    return unless $self->check_script;
    kill TERM => $pid;
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

1;
