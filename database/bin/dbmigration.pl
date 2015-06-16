#!/usr/bin/perl -w

package BOM::DBMigration;

use Moose;
use DBIx::Migration;
use Term::ReadKey;
use Sys::Hostname qw(hostname);
use File::Slurp;

with 'App::Base::Script';

sub cli_template {
    return "$0 [options]";
}

sub documentation {
    return qq#
This script will apply the SQL patched from a speicfied diretory to database.

Patch files names must be like:
schema_1_down.sql
schema_1_up.sql

Note: We dont support the downgrading.

use example_bomdb_migration.sql as a guide to how to make changesets.

Current version of database schema will be stored inside database in "dbix_migration" table. This table is used by Migration packge to keep the state of database.

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
            name    => 'dbset',
            dispaly => 'dbset=<dbset>',
            documentation =>
                'If dbset is rmg or feed or auth default directory,port and username will be set automactically <rmg|collector|report|feed|auth|users>',
            option_type => 'string',
            default     => '',
        },
        {
            name          => 'ask-password',
            documentation => 'Script will ask for password if this option is present.',
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
    my $password = 'letmein';
    my $tablename_extension;

    my $database = 'regentmarkets';
    my $port     = 5432;
    my $dir      = '/home/git/bom/database/config/sql/rmgdb';

    my $dbset = $self->getOption('dbset');
    if ($dbset eq 'rmg') {
        $dir = '/home/git/bom/database/config/sql/rmgdb';
    } elsif ($dbset eq 'collector') {
        $dir = '/home/git/bom/database/config/sql/collectordb';

        # version table = dbix_migration_collector
        $tablename_extension = 'collector';
    } elsif ($dbset eq 'feed') {
        $dir      = '/home/git/bom/database/config/sql/feeddb';
        $port     = '5433';
        $database = 'feed';
    } elsif ($dbset eq 'auth') {
        $dir      = '/home/git/bom/database/config/sql/authdb';
        $port     = '5435';
        $database = 'auth';
    } elsif ($dbset eq 'users') {
        $dir      = '/home/git/bom/database/config/sql/userdb';
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

    $self->print_info("hostname:" . $hostname);

    $self->print_info("port:" . $port);
    $self->print_info("database:" . $database);
    $self->print_info("username:" . $username);
    $self->print_info("dir:" . $dir);

    my $param = {
        'dsn'      => 'dbi:Pg:dbname=' . $database . ';host=' . $hostname . ';port=' . $port,
        'dir'      => $dir,
        'username' => $username,
        'password' => $password,
    };
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
    }

}

sub _confirm_database_versioning_changes {
    my $self            = shift;
    my $dir             = shift;
    my $current_version = shift;

    $self->print_info("Please confirm the changes.");

    $self->print_info("Upgrade statements from version $current_version to lastest version:");
    $self->print_info("===============================================");
    $current_version++;
    my $c = '';
    while (-e $dir . '/schema_' . $current_version . '_up.sql') {
        $c = File::Slurp::read_file($dir . '/schema_' . $current_version . '_up.sql');
        $self->print_info($c);
        $current_version++;
    }

    $self->print_info("===============================================");
    $self->print_info("Are you sure you want to apply this changes [y/N]?");
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
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::DBMigration->new->run;
