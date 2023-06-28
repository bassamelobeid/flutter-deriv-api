package BOM::Database::Script::CircuitBreaker;
use strict;
use warnings;
no indirect qw(fatal);
use utf8;

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use IO::Async::Function;
use IO::Async::File;
use Log::Any qw($log);
use Path::Tiny;
use DBI;
use POSIX                      qw(:signal_h);
use Time::HiRes                qw(ualarm usleep);
use DataDog::DogStatsd::Helper qw(stats_inc);

=head1 NAME

circuitbreaker.pl - monitor pgbouncer and suspend/resume databases as needed

=head1 DESCRIPTION

This script will connect to pgbouncer and check the status of each database. If a database is down, it will suspend the database in pgbouncer. If the database comes back up, it will resume the database in pgbouncer.

=head1 CONTEXT

The aim here is to prevent a problem in one DB from affecting other databases through an avalanche effect.

The idea is: All our connections (should) go through pgbouncer. A database in pgbouncer can be in several states. For instance we can suspend a database which would prevent further connections. Also, we can kill all existing connections to a DB.

Based on that here comes the idea. Every second we try to connect to a DB. Upon failure, we suspend the DB in the local pgbouncer and kill existing connections. Subsequent connections from the clients will be rejected quickly. So, the code can react to the error immediately without having to wait for a timeout. Connection attempts to the local pgbouncer are cheap.

Once a DB is suspended, we try to connect to it regularly. Depending on the kind of failure, the connection attempt can return quickly or run into a timeout. We might want to distinguish these 2 cases, but for a first implementation I don't think that is necessary. That means a connection attempt can result in success or failure. In the success case we turn the DB in pgbouncer back on. We can implement a timeout here or require several successful connections to ensure the DB is in good condition. A random timeout can also be useful to achieve a slow ramp-up effect of DB load. However, it normally takes a while for clients to come back. This could be enough of a ramp-up.

For more information, please see https://redmine.deriv.cloud/issues/88808#Circuit_breaker_for_the_database_connection

This module will fork several suprocess to check every database. They will die if that database is dead. And main process will check their status. If subprocess keep living, then that db will be resumed in pgbouncer. If one subprocess died, then that db will be suspended.
For tolerance, we will check 3 times before suspend it when a db turns to offline from online. 

When we send it a HUP signal, it will reload the config file and restart the process. If you change the config file, it will also be reloaded and restarted.

=cut

my $loop;
my $DATADOG_PREFIX = 'circuitbreaker';

=head1 SYNOPSIS

    my $breaker = BOM::Database::Script::CircuitBreaker->new(
        cfg_file => '/etc/pgbouncer/databases.ini',
        bouncer_uri => 'postgresql://postgres@:6432/pgbouncer',
        check_interval => 1,
        delay_interval => 1,
    );
    $breaker-run();

=head1 FUNCTIONS

=head2 new

    my $breaker = BOM::Database::Script::CircuitBreaker->new(
        cfg_file => '/etc/pgbouncer/databases.ini',
        bouncer_uri => 'postgresql://postgres@:6432/pgbouncer',
        check_interval => 1,
        delay_interval => 1,
    );

create a new instance of BOM::Database::Script::CircuitBreaker and init it

param: cfg_file - the path to the pgbouncer config file
param: bouncer_uri - the uri to the pgbouncer database
param: check_interval - the interval to wait subprocess die in main process, if not die then db status is ok
param: delay_interval - the interval to check subprocess again in main process

return: the instance of BOM::Database::Script::CircuitBreaker

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless \%args, $class;
    $self->{bouncer_uri} ||= 'postgresql://postgres@:6432/pgbouncer';
    $self->{cfg_file} =
        path($self->{cfg_file} || '/etc/pgbouncer/databases.ini');
    my $check_interval = $self->{check_interval} ||= 1;    # if no error in check_interval seconds, then we think db is aliving
    my $delay_interval = $self->{delay_interval} ||= 1;    # we will check again after delay_interval seconds
    $self->cfg();
    $self->{function} = IO::Async::Function->new(
        code        => sub { check_database_status_worker(@_, $check_interval, $delay_interval) },
        max_workers => scalar(keys $self->{cfg}->%*),
    );
    $loop = IO::Async::Loop->new;
    $loop->add($self->{function});
    $self->{keep_running} = 1;
    $SIG{HUP} = sub {                                      ## no critical (RequireLocalizedPunctuationVars)
        $log->info("got HUP signal, reload config file");
        $self->restart;
    };
    my $file = IO::Async::File->new(
        filename         => $self->{cfg_file},
        on_mtime_changed => sub {
            $log->info("config file changed, reload config file");
            $self->restart;
        },
    );
    $loop->add($file);
    return $self;
}

=head2 restart

  self->restart

=cut

sub restart {
    my $self = shift;
    $self->cfg();
    $self->{keep_running} = 0;
    $_->kill(15) for (values $self->{function}{workers}->%*);
    $self->{function}{max_workers} = scalar(keys $self->{cfg}->%*);
    $self->{function}->restart;
}

=head2 cfg

get pgbouncer configuration from config file, and store it in $self->{cfg}

return: $self

=cut

sub cfg {
    my $self = shift;
    $log->info("loading pgbouncer config file");
    my $cfg_file = $self->{cfg_file};
    my %cfg      = ();
    for my $l ($cfg_file->lines()) {
        my ($db, %p);
        next if $l =~ /_test =/;              # skip test db
        next if $l =~ /^\s*(?:#.*)?$/;
        next if $l =~ /^\s*\[databases\]$/;
        ($db, $l) = split /\s*=\s*/, $l, 2;
        %p = map { split /\s*=\s*/ } split /\s+/, $l;
        my $url = "postgresql://$p{user}:$p{password}\@$p{host}:$p{port}/$p{dbname}";
        $log->debugf("url is %s", $url);
        push $cfg{$url}->@*, $db;
    }
    $self->{cfg} = \%cfg;
    return $self;
}

=head2 operation

do operation on pgbouncer. Send command to pgbouncer

param: $op - the command that will be sent to pgbouncer
param: $dblist - the db name that will be operated on

return: the result of the operation

=cut

async sub operation {
    my ($self, $op, $dblist) = @_;

    # Database::Async does not support PG's simple query protocol. Pgbouncer
    # only speaks the simple protocol. So, we can't use Database::Async to
    # access pgbouncer. Hence, the external process.
    my $cmd = join(
        '',
        map { "$_;\n" }
            map {
            my $db = $_;
            map { (my $x = $_) =~ s/\^/$db/gr } @$op
            } @$dblist
    );
    return await $loop->run_process(
        command => [qw/psql -qXAt -v ON_ERROR_STOP=1/, $self->{bouncer_uri}],
        stdin   => $cmd,
        capture => [qw/exitcode stderr/],
    );
}

=head2 suspend

suspend dbs in pgbouncer

param: $list - the list of dbs that will be suspended

return: 1

=cut

async sub suspend {
    my ($self, $list) = @_;

    my ($rc, $stderr) = await $self->operation(['DISABLE "^"', 'KILL "^"'], $list);
    if ($rc) {
        $log->error("failed to suspend @$list\nPSQL STDERR:\n$stderr");
    } else {
        stats_inc("$DATADOG_PREFIX.suspend.$_") for @$list;
        $log->info("suspended @$list");
    }
    return;
}

=head2 resume

resume dbs in pgbouncer

param: $list - the list of dbs that will be resumed

return: 1

=cut

async sub resume {
    my ($self, $list) = @_;

    my ($rc, $stderr) = await $self->operation(['RESUME "^"', 'ENABLE "^"'], $list);
    if ($rc) {
        # we ignore the error if the DB was already resumed
        unless ($stderr =~ /is not paused/) {
            $log->error("failed to resume @$list\nPSQL STDERR:\n$stderr");
        }
    } else {
        stats_inc("$DATADOG_PREFIX.resume.$_") for @$list;
        $log->info("resumed @$list");
    }
    return 1;
}

=head2 check_database_status

    $self->check_database_status($uri);

check the status of the database, and suspend it if it is down, resume it if it is up. This method will run forever.

param: $uri - the uri of the database


=cut

async sub check_database_status {
    my $self = shift;
    my $uri  = shift;

    my $db_list = $self->{cfg}{$uri};

    # as default we don't know the db status
    my $online = undef;
    while ($self->{keep_running}) {
        $online = await $self->do_check($uri, $db_list, $online);
    }
}

=head2 do_check

    $self->do_check($uri, $db_list, $online);

check the status of the database, and suspend it if it is down, resume it if it is up.

param: $uri - the uri of the database
param: $db_list - the list of db names
param: $online - the status of the database, undef means unknown, 1 means online, 0 means offline

=cut

async sub do_check {
    my ($self, $uri, $db_list, $online) = @_;
    try {

        # if it was online or unknown status, we try 3 times to make sure it is really down
        my $times = $online || !defined($online) ? 3 : 1;
        for my $t (1 .. $times) {
            # if the function call is ready, we need to await it to clear states, to release function worker
            # It will happen when the worker get a 'TERM' signal
            if ($self->{function_call}{$uri} && $self->{function_call}{$uri}->is_ready) {
                my $f = delete $self->{function_call}{$uri};
                await $f;
            }
            if (!$self->{function_call}{$uri}) {
                $self->{function_call}{$uri} = $self->{function}->call(args => [$uri]);
            }

            try {
                await Future->wait_any(
                    $self->{function_call}{$uri}->without_cancel,
                    $loop->delay_future(after => $self->{check_interval})
                    ,    # if in 1 seconds there is no error from the function, we assume it is online
                );
                last;
            } catch ($e) {
                # here the function call is failed already, so we need to delete it from the hash to avoid impacting the next test
                delete $self->{function_call}{$uri};
                if ($e =~ /^Timeout/) {
                    stats_inc("$DATADOG_PREFIX.timeout.$_") for @$db_list;
                } elsif ($e =~ /^TERM/) {
                    #keep current status if get TERM
                    $log->debug("$uri get TERM");
                    return $online;
                } else {
                    stats_inc("$DATADOG_PREFIX.failure.$_") for @$db_list;
                }
                if ($t == $times) {
                    die $e;
                }
                await $loop->delay_future(after => $self->{delay_interval});
            }
        }
        $log->debug("SUCCESS $uri");
        unless ($online) {
            try {
                await $self->resume($db_list);
                $online = 1;
            } catch ($e) {
                $log->error("failed to resume $uri: $e");
            }
        }
        await $loop->delay_future(after => $self->{delay_interval});
    } catch ($e) {
        if ($e =~ /^TERM/) {
            #keep current status if get TERM
            $log->debug("$uri get TERM");
            return $online;
        }
        $log->debug("FAIL $uri -- $e");
        if ($online || !defined($online)) {
            try {
                await $self->suspend($db_list);
                $online = 0;
            } catch ($e) {
                $log->error("failed to suspend $uri: $e");
            }
        }
        await $loop->delay_future(after => $self->{delay_interval});
    }
    my $state = $online ? 'online' : 'offline';
    stats_inc("$DATADOG_PREFIX.state.$state", {tags => ["server:$_"]}) for @$db_list;
    return $online;
}

=head2 run

    $self->run();

run the check forever

=cut

sub run {
    my $self = shift;
    while (1) {
        Future->wait_all(
            map { $self->check_database_status($_) }
                keys $self->{cfg}->%*
        )->get;
        $self->{keep_running} = 1;
    }
}

=head2 check_database_status_worker
  
      check_database_status_worker($url, $check_interval, $delay_interval);

Check the status of the database. This function will run forever. If any eror happens, it will die.

param: $url - the url of the database
check_interval: the interval to check the database status
delay_interval: the interval to wait before next check
return: never return

=cut

sub check_database_status_worker {
    my ($url, $check_interval, $delay_interval) = @_;
    $log->debug("$$ running call on $url");
    # rename process name
    $0        = "circuitbreaker.pl: $url";    ## no critic (LocalizedPunctuationVars)
                                              # reset HUP signal
    $SIG{HUP} = sub {                         ## no critic (LocalizedPunctuationVars)
        $log->warnf("$$ subprocess received HUP signal, please send to main process %s", getppid());
    };

    # reset TERM signal
    $SIG{TERM} = sub { $log->debug("$$ received TERM signal."); die "TERM\n"; };    ## no critic (LocalizedPunctuationVars)

    # The reason that SIGALRM is not used, please refer to https://metacpan.org/pod/DBI#Timeout
    my $mask   = POSIX::SigSet->new(SIGALRM);                                       # signals to mask in the handler
    my $action = POSIX::SigAction->new(
        sub { die "Timeout\n" },                                                    # the handler code ref
        $mask,
    );
    my $oldaction = POSIX::SigAction->new();
    sigaction(SIGALRM, $action, $oldaction);
    # die quicklier than check_interval to avoid such case:
    # suppose we set a higher  alarm time, when server can accept connection but no response, then caller think
    # server is ok, and in the next loop, alarm happen, then caller then think server is down, and tr again,
    # and then same case happen again and again
    my $alarm_us = $check_interval * 0.9 * 1_000_000;
    try {
        try {
            ualarm $alarm_us;
            my ($user, $password, $host, $port, $dbname) = $url =~ m{postgresql://(.*):(.*)\@(.*):(.*)/(.*)};
            my $dbi = DBI->connect(
                "DBI:Pg:database=$dbname;host=$host;port=$port",
                $user,
                $password,
                {
                    RaiseError => 1,
                    PrintError => 0
                });
            while (1) {
                ualarm $alarm_us;
                $dbi->do("select 1");
                ualarm 0;
                usleep $delay_interval * 1_000_000;
            }
        } catch ($e) {
            ualarm 0;
            die $e;
        }
    } catch ($e) {
        sigaction(SIGALRM, $oldaction);
        die $e;
    }
}

1;
