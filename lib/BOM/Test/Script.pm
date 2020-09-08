package BOM::Test::Script;
use strict;
use warnings;

BEGIN {
    local $ENV{NO_PURGE_REDIS} = 1;
    require BOM::Test;
}
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
    return 0 unless $self->script;
    return 1 if $self->check_script();
    return $self->start_script();
}

sub start_script {
    my $self   = shift;
    my $script = $self->script;
    return 0 unless $script;
    my $pid_file = $self->pid_file;
    $pid_file->remove;

    my $args = $self->args // [];
    my $pid  = fork();
    die "Cannot fork to run script $script" unless defined($pid);

    unless ($pid) {
        local $ENV{NO_PURGE_REDIS} = 1;
        exec($^X, qw(-MBOM::Test), $script, '--pid-file', $pid_file, @$args) or die "Couldn't execute $script: $!";
    }

    for (1 .. 10) {
        return 1 if $pid_file->exists;
        sleep 1;
    }

    return 0;
}

sub stop_script {
    my $self = shift;
    my $pid  = $self->pid;
    return unless $self->check_script;
    kill TERM => $pid;
    $self->wait_till_exit($pid, 10);
    return;
}

sub wait_till_exit {
    my ($self, $pid, $timeout) = @_;
    # if the subprocess is the child, we reap it
    my $waitpid = waitpid($pid, 0);
    #reset $? to avoid affecting exit code in the END block
    ## no critic (RequireLocalizedPunctuationVars)
    $? = 0;

    return if $pid == $waitpid;

    # else test it with kill ZERO
    my $start = time;
    while (time - $start < $timeout and kill ZERO => $pid) {
        print "wait $pid...\n";
        sleep 1;
    }
    return;
}

1;
