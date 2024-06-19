package BOM::Platform::Desk;

use Moo;

use strict;
use warnings;

=head1 NAME

BOM::Platform::Desk - aws s3 communicator between binary-desk-com-backup bucket and internal system.

=head1 SYNOPSIS

BOM::Platform::Desk->new(user => $user_instance);

=head1 DESCRIPTION

An interface to aws s3 binary-desk-com-backup bucket in aws. Handle API communications and some internal actions.

=cut

use Future::AsyncAwait;
use Log::Any qw{$log};
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::Database::ClientDB;
use BOM::User;
use BOM::Platform::S3Client;

use constant BUCKET_NAME => 'binary-desk-com-backup';

=head2 user

user instance.

=cut

has user => (
    is       => 'ro',
    required => 1
);

=head2 _s3_client_instance

BOM::Platform::S3Client instance.

=cut

has _s3_client_instance => (
    is      => 'ro',
    default => sub {
        my $config = BOM::Config::s3()->{binary_desk};

        die "aws_bucket is missing."            unless $config->{aws_bucket};
        die "aws_access_key_id is missing."     unless $config->{aws_access_key_id};
        die "aws_secret_access_key is missing." unless $config->{aws_secret_access_key};

        my $s3_client = BOM::Platform::S3Client->new($config);

        return $s3_client;
    });

=head2 _db_instance

Single instance to communicate with collector db

=cut

has _db_instance => (
    is      => 'ro',
    default => sub {
        my $collector_db = BOM::Database::ClientDB->new({
                broker_code => 'FOG',
                operation   => 'collector'
            })->db->dbic;

        return $collector_db;
    });

=head2 get_user_file_path

Combine/Return user related file paths from Database and S3 bucket.

=cut

async sub get_user_file_path {
    my $self = shift;

    my $user_id = $self->user->id;
    my @files;

    try {

        @files = $self->_get_file_path_db($user_id);

        if (scalar @files) {
            push @files, await $self->_get_file_path_s3(\@files);

            # remove all prefixes
            @files = grep { $_ !~ /^desk\/case\/\w+\/$/ } @files;
        }

    } catch ($e) {
        $log->errorf("Error while retrieving user $user_id related desk files: $e");
        return undef;
    }

    return @files;
}

=head2 anonymize_user

Delete all user related file path from both Database and S3 bucket.

=cut

async sub anonymize_user {
    my $self = shift;

    my $user_id = $self->user->id;

    try {

        die "user_id is missing" unless $user_id;

        my @files = await $self->get_user_file_path;

        await $self->_delete_user_file_path_s3(\@files);
        $self->_delete_user_file_path_db($user_id);
    } catch ($e) {
        $log->errorf("Error while anonymizing user $user_id desk files: $e");
        return 0;
    }

    return 1;
}

=head2 _delete_user_file_path_s3

=over 4

=item * C<file_list> - array_ref contains all file paths

=back

Delete files from S3 - Returns nothing.

=cut

async sub _delete_user_file_path_s3 {
    my ($self, $file_list) = @_;

    die "file_list is missing" unless $file_list;

    foreach my $file_path ($file_list->@*) {
        await $self->_s3_client_instance->delete($file_path);
    }

    return 1;
}

=head2 _delete_user_file_path_db

=over 4

=item * C<user_id> - user id to use in db query. 

=back

Delete files from Databse - Returns nothing.

=cut

sub _delete_user_file_path_db {
    my ($self, $user_id) = @_;

    die "user_id is missing" unless $user_id;

    my @files = $self->_get_file_path_db($user_id);

    my $bucket_id = $self->_db_instance->run(
        ping => sub {
            $_->selectall_array('SELECT id FROM data_collection.get_bucket_id(?)', undef, BUCKET_NAME);
        });

    foreach my $file_path (@files) {
        $self->_db_instance->run(
            ping => sub {
                $_->do('SELECT data_collection.delete_user_file_path(?, ?)', undef, $bucket_id, $file_path);
            });
    }

    return undef;
}

=head2 _get_file_path_db

=over 4

=item * C<user_id> - user id to use in db query.

=back

Select/Return user related file paths from db.

=cut

sub _get_file_path_db {
    my ($self, $user_id) = @_;

    die "user_id is missing" unless $user_id;

    my @db_files = map { $_->[0] } $self->_db_instance->run(
        ping => sub {
            $_->selectall_array('SELECT path FROM data_collection.get_user_file_path(?)', undef, $user_id);
        });

    return @db_files;
}

=head2 _get_file_path_s3

=over 4

=item * C<file_list> - array_ref contains all file paths.

=back

List/Return user related file path from s3.

=cut

async sub _get_file_path_s3 {
    my ($self, $file_list) = @_;

    die "file_list is missing" unless $file_list;

    my @lookup_file_prefixes = grep { $_ =~ /^desk\/case\// } $file_list->@*;

    my @s3_files;

    foreach my $prefix (@lookup_file_prefixes) {
        my ($record) = await $self->_s3_client_instance->list_bucket($prefix);

        my @keys = map { $_->{key} } $record->@*;

        push @s3_files, @keys;
    }

    return @s3_files;
}

1;
