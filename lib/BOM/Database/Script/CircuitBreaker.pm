package BOM::Database::Script::CircuitBreaker;
use strict;
use warnings;
no indirect qw(fatal);
use utf8;

use Future::AsyncAwait;
use Syntax::Keyword::Try;
use IO::Async::Loop;
use IO::Async::Function;
use Log::Any qw($log);
use Path::Tiny;
use DBI;
use DataDog::DogStatsd::Helper qw(stats_inc);

=head1 NAME

circuitbreaker.pl - monitor pgbouncer and suspend/resume databases as needed

=head1 DESCRIPTION

This script will connect to pgbouncer and check the status of each database. If a database is down, it will suspend the database in pgbouncer. If the database comes back up, it will resume the database in pgbouncer.

=head1 CONTEXT

The aim here is to prevent a problem in one DB from affecting other databases through an avalanche effect.

The idea is: All our connections (should) go through pgbouncer. A database in pgbouncer can be in several states. For instance we can suspend a database which would prevent further connections. Also, we can kill all existing connections to a DB.

Based on that here comes the idea. Ever second we try to connect to a DB. Upon failure, we suspend the DB in the local pgbouncer and kill existing connections. Subsequent connections from the clients will be rejected quickly. So, the code can react to the error immediately without having to wait for a timeout. Connection attempts to the local pgbouncer are cheap.

Once a DB is suspended, we try to connect to it regularly. Depending on the kind of failure, the connection attempt can return quickly or run into a timeout. We might want to distinguish these 2 cases, but for a first implementation I don't think that is necessary. That means a connection attempt can result in success or failure. In the success case we turn the DB in pgbouncer back on. We can implement a timeout here or require several successful connections to ensure the DB is in good condition. A random timeout can also be useful to achieve a slow ramp-up effect of DB load. However, it normally takes a while for clients to come back. This could be enough of a ramp-up.

For more information, please see https://redmine.deriv.cloud/issues/88808#Circuit_breaker_for_the_database_connection

=cut

my $loop;
my $DATADOG_PREFIX = 'circuitbreaker';

=head1 FUNCTIONS

=head2 new

    my $breaker = BOM::Database::Script::CircuitBreaker->new(
        cfg_file => '/etc/pgbouncer/databases.ini',
        bouncer_uri => 'postgresql://postgres@:6432/pgbouncer',
    );

create a new instance of BOM::Database::Script::CircuitBreaker and init it

param: cfg_file - the path to the pgbouncer config file
param: bouncer_uri - the uri to the pgbouncer database

return: the instance of BOM::Database::Script::CircuitBreaker

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless \%args, $class;
    $self->{bouncer_uri} ||= 'postgresql://postgres@:6432/pgbouncer';
    $self->{cfg_file} =
        path($self->{cfg_file} || '/etc/pgbouncer/databases.ini');

    $loop = IO::Async::Loop->new;
    $self->{function} = IO::Async::Function->new(
        code => sub {
            my $url = shift;
            my ($user, $password, $host, $port, $dbname) = $url =~ m{postgresql://(.*):(.*)\@(.*):(.*)/(.*)};
            my $dbi = DBI->connect(
                "DBI:Pg:database=$dbname;host=$host;port=$port",
                $user,
                $password,
                {
                    RaiseError => 1,
                    PrintError => 0
                });
            $dbi->do("select 1");
        });
    $loop->add($self->{function});

    $self->cfg();

    return $self;
}

=head2 cfg

get pgbouncer configuration from config file, and store it in $self->{cfg}

return: $self

=cut

sub cfg {
    my $self     = shift;
    my $cfg_file = $self->{cfg_file};
    my %cfg      = ();
    for my $l ($cfg_file->lines()) {
        my ($db, %p);
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
    while (1) {
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
            try {
                await Future->wait_any($loop->timeout_future(after => 2), $self->{function}->call(args => [$uri]),);
                last;
            } catch ($e) {
                if ($e =~ /^Timeout/) {
                    stats_inc("$DATADOG_PREFIX.timeout.$_") for @$db_list;
                } else {
                    stats_inc("$DATADOG_PREFIX.failure.$_") for @$db_list;
                }
                if ($t == $times) {
                    die $e;
                }
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
        await $loop->delay_future(after => 1);
    } catch ($e) {
        $log->debug("FAIL $uri -- $e");
        if ($online || !defined($online)) {
            try {
                await $self->suspend($db_list);
                $online = 0;
            } catch ($e) {
                $log->error("failed to suspend $uri: $e");
            }
        }
        await $loop->delay_future(after => 1 + rand(4));
    }
    return $online;
}

=head2 run

    $self->run();

run the check forever

=cut

sub run {
    my $self = shift;
    Future->wait_all(
        map { $self->check_database_status($_) }
            keys $self->{cfg}->%*
    )->get;
}

1;
