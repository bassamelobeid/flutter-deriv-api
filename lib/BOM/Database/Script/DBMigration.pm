package BOM::Database::Script::DBMigration;

# See also https://github.com/regentmarkets/devops-docs/wiki/DB-schema-and-function-application-procedure

use Moose;
use DBIx::Migration;
use Term::ReadKey;
use Sys::Hostname qw(hostname);
use File::Slurp;

with 'App::Base::Script';

my $home_git = $ENV{HOME_GIT_DIR} // '/home/git';

sub cli_template {
    return "$0 [options]";
}

sub documentation {
    return qq#
This script will apply the SQL patched from a specific directory to a database.

Patch files names must be like:
schema_1_up.sql

Note: We don't support the downgrading.

Current version of database schema will be stored inside database in "dbix_migration" table. This table is used by Migration package to keep the state of database.

MAKE A BACKUP BEFORE ANY MAJOR CHANGE ON LIVE SERVER.
#;
}

sub options {
    return [{
            name          => 'hostname',
            display       => 'hostname=<hostname>',
            documentation => 'Target DB to update',
            option_type   => 'string',
            default       => 'localhost'
        },
        {
            name          => 'port',
            display       => 'port=<port>',
            documentation => 'Target DB port',
            option_type   => 'string',
            default       => '',
        },
        {
            name          => 'dir',
            display       => 'dir=<dir>',
            documentation => 'The directory that contains migration schema files (e.x schema_12_up.sql).',
            option_type   => 'string',
            default       => '',
        },
        {
            name          => 'database',
            display       => 'database=<db>',
            documentation => 'Which databaseto update',
            option_type   => 'string',
            default       => '',
        },
        {
            name          => 'username',
            display       => 'username=<user>',
            documentation => 'DB usrename',
            option_type   => 'string',
            default       => 'postgres',
        },
        {
            name          => 'dbset',
            display       => 'dbset=<dbset>',
            documentation =>
                'one of <rmg|collector|report|feed|auth|users> - for rmg, feed or auth, the default directory/port/username will be set automatically',
            option_type => 'string',
            default     => '',
        },
        {
            name          => 'ask-password',
            documentation => 'Script will ask for password if this option is present.',
        },
        {
            name          => 'service',
            display       => 'service=<pg_service>',
            documentation => 'Specifying a PG service superseeds hostname, port, database, username and password specifications.',
            option_type   => 'string',
            default       => '',
        },
        {
            name          => 'yes',
            documentation => 'Don\'t ask again.',
        },

    ];
}

sub script_run {
    my $self = shift;

    my $hostname = $self->getOption('hostname');
    my $username = $self->getOption('username');
    my $password = 'mRX1E3Mi00oS8LG';
    my $tablename_extension;
    my $service;

    my $database = 'regentmarkets';
    my $port     = 5432;
    my $dir      = $home_git . '/regentmarkets/bom-postgres-clientdb/config/sql/';

    my $dbset = $self->getOption('dbset');
    if ($dbset eq 'rmg') {
        $dir = $home_git . '/regentmarkets/bom-postgres-clientdb/config/sql/';
    } elsif ($dbset eq 'collector') {
        $dir = $home_git . '/regentmarkets/bom-postgres-collectordb/config/sql/';

        # version table = dbix_migration_collector
        $tablename_extension = 'collector';
    } elsif ($dbset eq 'crypto') {
        $dir      = $home_git . '/regentmarkets/bom-postgres-cryptodb/config/sql/';
        $database = 'crypto';
    } elsif ($dbset eq 'chronicle') {
        $dir      = $home_git . '/regentmarkets/bom-postgres-chronicledb/config/sql/';
        $port     = '5437';
        $database = 'chronicle';
    } elsif ($dbset eq 'feed') {
        $dir      = $home_git . '/regentmarkets/bom-postgres-feeddb/config/sql/';
        $port     = '5433';
        $database = 'feed';
    } elsif ($dbset eq 'auth') {
        $dir      = $home_git . '/regentmarkets/bom-postgres-authdb/config/sql/';
        $port     = '5435';
        $database = 'auth';
    } elsif ($dbset eq 'users') {
        $dir      = $home_git . '/regentmarkets/bom-postgres-userdb/config/sql';
        $port     = '5436';
        $database = 'users';
    }

    if ($self->getOption('ask-password')) {
        print "Password:";
        ReadMode 4;
        my $pass = ReadLine(0, *STDIN);
        chomp $pass;
        $password = $pass;
        ReadMode 0;
    }

    if ($self->getOption('database')) {
        $database = $self->getOption('database');
    }
    if ($self->getOption('dir')) {
        $dir = $self->getOption('dir');
    }
    if ($self->getOption('port')) {
        $port = $self->getOption('port');
    }

    $service = $self->getOption('service');

    my $param = {
        'dir' => $dir,
    };

    if ($service) {
        $self->print_info("service:" . $service);
        $self->print_info("dir:" . $dir);

        $param->{dsn} = 'dbi:Pg:service=' . $service;
    } else {
        $self->print_info("hostname:" . $hostname);
        $self->print_info("port:" . $port);
        $self->print_info("database:" . $database);
        $self->print_info("username:" . $username);
        $self->print_info("dir:" . $dir);

        @{$param}{qw/dsn username password/} = ('dbi:Pg:dbname=' . $database . ';host=' . $hostname . ';port=' . $port, $username, $password,);
    }

    $param->{tablename_extension} = $tablename_extension if $tablename_extension;

    my $migration = DBIx::Migration->new($param);

    my $version_old = $migration->version || '0';
    #remove the spaces because table is using character not varchar
    $version_old =~ s/\s//g;
    if ($self->getOption('yes') or $self->_confirm_database_versioning_changes($dir, $version_old)) {
        $migration->migrate();

        my $version_new = $migration->version;
        $version_new =~ s/\s//g;

        $self->print_info("Update from version [$version_old] to version [$version_new]\n");
    } else {
        $self->print_info("Update had been cancelled.");
        exit 1;
    }
    return;
}

sub _confirm_database_versioning_changes {
    my $self            = shift;
    my $dir             = shift;
    my $current_version = shift;

    $self->print_info("Please confirm the changes.");

    $self->print_info("Upgrade statements from version $current_version to latest version:");
    $self->print_info("===============================================");
    $current_version++;
    my $c = '';
    while (-e $dir . '/schema_' . $current_version . '_up.sql') {
        $c = File::Slurp::read_file($dir . '/schema_' . $current_version . '_up.sql');
        $self->print_info($c);
        $current_version++;
    }

    $self->print_info("===============================================");
    $self->print_info("Are you sure you want to apply these changes [y/N]?");
    my $confirm = readline(*STDIN);
    chomp $confirm;

    if ($confirm ne 'y') {
        return;
    }

    return 1;
}

sub print_info {
    my $self = shift;
    my $c    = shift;
    print $c, "\n";
    return;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
