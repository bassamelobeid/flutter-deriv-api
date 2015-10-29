#!/usr/bin/env perl
package BOM::Platform::CouchDB::Maintenance::Replication;

use 5.010;
use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use BOM::Platform::Runtime;
use Array::Utils qw(array_minus);
use Time::HiRes qw(sleep);
use JSON::XS qw( decode_json encode_json );
use Try::Tiny;
use List::Util qw(first);
use LWP::UserAgent;
use Carp;

sub documentation {
    return qq/\nInspects replication delays and reinitialize replication if above threshold./
        . qq/\nAlso restarts CouchDB if it's stuck and replications cannot be stopped.'/;
}

sub options {
    return [{
            name          => 'dbs',
            display       => 'dbs=db1,db2,..',
            documentation => 'Comma separated list of databases to handle.',
            option_type   => 'string',
            default       => join(',', keys %{BOM::Platform::Runtime->instance->datasources->couchdb_databases}),
        },
        {
            name          => 'show-delays',
            documentation => 'Lists databases delays',
        },
        {
            name          => 'show-replications',
            documentation => 'Lists active replications',
        },
        {
            name => 'restart-stale',
            documentation =>
                'Find replications whose delays are over threshold and try to restart them. Kills and restarts CouchDB if they are stuck and cannot be reinstantiated.',
        },
        {
            name          => 'force-restart-couch',
            documentation => 'Only restart CouchDB. No replication is initiated.',
        },
        {
            name    => 'random-delay',
            display => 'random-delay=<n>',
            documentation =>
                'Wait for random <n> seconds before starting. This is just to avoid cron triggered replications to hit master server at same time',
            option_type => 'integer',
            default     => undef,
        },
        {
            name          => 'threshold',
            display       => 'threshold=<n>',
            documentation => 'How many seconds the replication can be delayied before being considered stuck',
            option_type   => 'integer',
            default       => 200,
        },
        {
            name          => 'update-replication-indicator',
            documentation => "update replication indicator in Master CouchDB",
        },
        {
            name          => 'start-replication',
            documentation => 'Starts replication for the specified databases',
        },
        {
            name          => 'stop-replication',
            documentation => 'Starts replication for the specified databases',
        },
        {
            name          => 'compact',
            documentation => "Compacts the specified databases",
        },
        {
            name          => 'destroy-databases',
            display       => 'destroy-databases=<db1,db2..>',
            documentation => 'Deletes the specified databases from couchdb',
            option_type   => 'string',
        },
        {
            name          => 'keep-revisions',
            display       => 'keep-revisions=<n>',
            documentation => "Limit revisions while compacting specified databases",
            option_type   => 'integer',
        },
        {
            name          => 'master-server',
            documentation => "The url of the master couch server to replicate from",
            option_type   => 'string',
            default       => BOM::Platform::Runtime->instance->datasources->couchdb->master->uri,
        },
    ];
}

has _dbs => (
    is      => 'ro',
    lazy    => 1,
    default => sub { return [split(',', shift->getOption('dbs'))] },
);

sub _delays {
    my $self = shift;
    return {map { $_ => $self->_replication_delay($_) } @{$self->_dbs}};
}

sub script_run {
    my $self      = shift;
    my $localhost = BOM::Platform::Runtime->instance->hosts->localhost;

    if ($self->getOption('show-delays')) {
        $self->info($self->_list_delays);
        return 0;
    }

    if ($self->getOption('show-replications')) {
        my $msg = join ', ', map { sprintf('%s: %s -> %s', $_->{replication_id}, $_->{source}, $_->{target}); } $self->_active_replications;
        $self->info($msg);
        return 0;
    }

    if ($self->getOption('update-replication-indicator')) {
        unless ($localhost->has_role('couchdb_master')) {
            $self->debug("Replication indicator is only updated from Master CouchDB. Doing nothing.");
            return 0;
        }

        $self->debug('updateing replication indicator');
        $self->_update_replication_indicator;
        return 0;
    }

    if ($self->getOption('force-restart-couch')) {
        $self->info('Forcing CouchDB restart.');
        $self->_force_restart_couchdb();
        return 0;
    }

    if ($self->getOption('compact')) {
        my $limit = $self->getOption('keep-revisions');
        $self->error("The --keep-revisions option is required for compaction") unless $limit && $limit > 0;
        $self->debug('Starting compaction..');
        $self->set_revision_limits($limit, @{$self->_dbs});
        $self->compact_dbs(@{$self->_dbs});
        return 0;
    }

    if (my $_dbs = $self->getOption('destroy-databases')) {
        my @dbs = split(',', $_dbs);
        if ($ENV{FORCEDESTROY}) {    # development only. intentionally undocumented.
            $self->warning('DELETING COUCH DATABASES: ' . join(', ', @dbs));
            $self->_destroy_databases(@dbs);
            return 0;
        } else {
            $self->error('Cannot destroy databases! Ask Farzad.');
        }
    }

    # the master database doesn't replicate from anywhere
    # it is the source from where everybody else replicates :-)
    if ($localhost->has_role('couchdb_master')) {
        unless ($ENV{FORCEONMASTER}) {    # development only. intentionally undocumented.
            $self->debug("Master CouchDB doesn't replicate from anywhere. Doing nothing.");
            return 0;
        }
    }

    if ($self->getOption('restart-stale')) {
        $self->debug('Trying to restart stale replications if any.');
        return $self->return_value($self->restart_stale);
    }

    if ($self->getOption('stop-replication')) {
        $self->debug('Stopping replications..');
        $self->_stop_replication(@{$self->_dbs});
        return 0;
    }

    if ($self->getOption('start-replication')) {
        $self->debug('Starting replications..');
        $self->_start_replication(@{$self->_dbs});
        return 0;
    }

    $self->usage();
    return $self->return_value(1);
}

sub restart_stale {
    my $self = shift;

    if (my $delay = $self->getOption('random-delay')) { sleep rand $delay }

    unless ($self->_is_couch_running()) {
        $self->info("CouchDB is not running! Starting..");
        $self->_start_couch();
    }

    my @inactive = $self->_inactive_replications;
    my @stale    = $self->_stale_replications;
    @stale = array_minus(@stale, @inactive);

    if (@stale) {
        $self->info("Replication is stale in databases: " . join(', ', @stale));
        $self->info("Restarting replication..");
        eval { $self->_restart_replication(@stale); 1 } or do {
            my $failed = $@;
            $self->info("Failed to stop replication for databases: " . join(', ', @$failed));
            $self->info("Forcing couchdb restart and attempting a second time..");
            $self->_force_restart_couchdb();
            eval {
                # We restarted couch, so we need to bring all replications back
                $self->_restart_replication(@{$self->_dbs});
                1;
            } or croak "Failed to start replication after restarting CouchDB. Giving up.";
        };

        # Double check it is really working..
        @stale = sort @stale;
        my @running = $self->_is_replication_running(@stale);
        if (@running ~~ @stale) {
            $self->info("Replications are running. Done.");
        } else {
            $self->info("Failed to reinitiate replications.");
            $self->info("Expected running: " . join(', ', @stale, @inactive));
            $self->info("Got: " . join(', ', @running));
            return 1;
        }
    } else {
        $self->debug("No stale replication found.");
    }

    if (@inactive) {
        $self->debug("Starting inactive replications: " . join(', ', @inactive));
        $self->_start_replication(@inactive);
    }

    return 0;
}

sub _inactive_replications {
    my $self = shift;
    my @active = map { $_->{target} } $self->_active_replications;
    return array_minus(@{$self->_dbs}, @active);
}

sub set_revision_limits {
    my ($self, $limit, @dbs) = @_;
    for my $dbname (@dbs) {
        $self->_set_revision_limit($limit, $dbname);
    }
    return;
}

sub _set_revision_limit {
    my ($self, $limit, $dbname) = @_;

    my $url = URI->new_abs("$dbname/_revs_limit", 'http://localhost:5984')->as_string;
    my $cmd = "curl --silent --show-error --request PUT --data '$limit' '$url'";
    return $self->_system($cmd);
}

sub compact_dbs {
    my ($self, @dbs) = @_;
    for my $dbname (@dbs) {
        $self->_compact($dbname);
    }
    return;
}

sub _compact {
    my ($self, $dbname) = @_;

    my $url = URI->new_abs("$dbname/_compact", 'http://localhost:5984')->as_string;
    my $cmd = "curl --silent --show-error -H 'Content-Type: application/json' --request POST '$url'";
    return $self->_system($cmd);
}

sub _list_delays {
    my $self = shift;
    my %a    = %{$self->_delays};
    my $msg  = join(', ', map { "$_: $a{$_}s" } @{$self->_dbs});
    return "Database replication delays: $msg";
}

sub repl_delay_threshold { return shift->getOption('threshold') }

sub _replication_delay {
    my $self        = shift;
    my $db_name_key = shift;

    my $db_name = BOM::Platform::Runtime->instance->datasources->couchdb_databases->{$db_name_key};
    my $db = BOM::Platform::Runtime->instance->datasources->couchdb($db_name, $self->_no_delay_ua);

    if ($db->can_read and $db->replica->database_exists and $db->document_present($self->_replication_doc_name)) {
        my $last_write_time = $db->document($self->_replication_doc_name)->{write_time};
        if ($last_write_time) {
            return time - $last_write_time;
        }
    }

    return 999900001;
}

sub _stale_replications {
    my $self   = shift;
    my $delays = $self->_delays;
    return grep { $delays->{$_} > $self->repl_delay_threshold } @{$self->_dbs};
}

sub _stop_replication {
    my ($self, @dbs) = @_;
    for my $dbname (@dbs) {
        $self->_replication($dbname, 'stop');
    }
    return;
}

sub _start_replication {
    my ($self, @dbs) = @_;
    for my $dbname (@dbs) {
        $self->_replication($dbname, 'start');
    }
    return;
}

sub _replication {
    my ($self, $dbname, $action) = @_;

    confess "Invalid action: $action" unless first { $action eq $_ } qw(start stop);

    my $source_url      = URI->new_abs($dbname,      $self->getOption('master-server'))->as_string;
    my $replication_url = URI->new_abs('_replicate', 'http://localhost:5984')->as_string;
    my $replication_args = {
        source        => $source_url,
        target        => $dbname,
        continuous    => \1,
        create_target => \1,
    };
    $replication_args->{cancel} = \1 if $action eq 'stop';
    $replication_args = encode_json($replication_args);

    my $cmd = "curl --silent --show-error -H 'Content-Type: application/json' --request POST --data '$replication_args' '$replication_url'";
    return $self->_system($cmd);
}

sub _is_replication_running {
    my ($self, @dbs) = @_;

    my %active_replications;
    try {
        %active_replications = map { $_->{target} => 1 } $self->_active_replications;
    }
    catch {
        when (/couldn't connect to host/) { }          # couch is not running, no replications active
        default                           { die $_ }
    };
    return grep { exists $active_replications{$_} } @dbs;
}

sub _active_replications {
    my ($self) = @_;
    my $cmd    = "curl --silent --show-error http://localhost:5984/_active_tasks";
    my $result = $self->_system($cmd);
    my @replications = grep { $_->{type} =~ /replication/i } @{decode_json($result)};
    return @replications;
}

sub _restart_replication {
    my ($self, @dbs) = @_;
    $self->_stop_replication(@dbs);
    if (my @stuck = $self->_is_replication_running(@dbs)) {
        croak(\@stuck);
    }
    $self->_start_replication(@dbs);
    return;
}

my $couchid = '/var/run/couchdb/couchdb.pid';

sub _is_couch_running {
    local $? = $?;
    `pgrep -f $couchid`;    # Avoids output going to STDOUT
    return $? == 0;
}

sub _kill_couch {
    my ($self) = @_;
    try {
        $self->_system("pkill -KILL -u couchdb -f 'heart -pid|$couchid'");
    }
    catch {
        when (/Failed with exit code 1/) { }          # process not found, already died/exited; that's ok.
        default                          { die $_ }
    }
}

sub _start_couch {
    local $? = $?;
    `service couchdb start >/dev/null 2>/dev/null`;
    return if $? != 0;

    # Wait for couch to be responsive
    for (1 .. 10) {
        `curl -s http://localhost:5984/_all_dbs`;
        return 1 if $? == 0;
        sleep 0.5;
    }
    return;
}

sub _force_restart_couchdb {
    my $self = shift;
    $self->_kill_couch();
    for (1 .. 10) {
        last unless $self->_is_couch_running();
        sleep 0.5;
    }
    croak('Failed to kill couchdb') if $self->_is_couch_running();
    $self->_start_couch() or croak('Failed to start couchdb');
    return;
}

sub _update_replication_indicator {
    my $self = shift;
    grep {
        my $db_name = $_;
        my $db = BOM::Platform::Runtime->instance->datasources->couchdb($db_name, $self->_no_delay_ua);
        if ($db->replica->database_exists) {
            if (!$db->document_present($self->_replication_doc_name)) {
                $db->create_document($self->_replication_doc_name);
            }

            $db->document(
                $self->_replication_doc_name,
                {
                    write_time => time,
                    data       => 'This is a test document for checking if the replication is alive'
                });

            $self->debug("replication indicator of $db is updated");
        } else {
            $self->error("CouchDB database " . $db_name . " does not exists");
        }
    } values %{BOM::Platform::Runtime->instance->datasources->couchdb_databases};
    return;
}

sub _destroy_databases {
    my ($self, @dbs) = @_;
    foreach (@dbs) {
        my $url = URI->new_abs($_, 'http://localhost:5984')->as_string;
        my $cmd = "curl --silent --show-error --request DELETE '$url'";
        $self->_system($cmd);
    }
    return;
}

sub _system {
    my ($self, $cmd) = @_;

    local $?;
    my $result = `$cmd 2>&1`;
    confess 'Failed with exit code ' . ($? >> 8) . " while running\n`$cmd`\nOutput: $result" if $?;
    return $result;
}

sub _no_delay_ua {
    my $self = shift;
    return LWP::UserAgent->new(
        agent   => $self->meta->name,
        timeout => 1,
    );
}

has '_replication_doc_name' => (
    is      => 'ro',
    default => 'snmp_replication_doc',
);

no Moose;
__PACKAGE__->meta->make_immutable;
1;

exit __PACKAGE__->new->run unless caller;
