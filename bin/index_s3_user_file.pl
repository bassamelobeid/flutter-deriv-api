#!/etc/rmg/bin/perl

use strict;
use warnings;

use Amazon::S3;
use Cache::LRU;
use Getopt::Long;
use JSON::MaybeXS qw{encode_json decode_json};
use Log::Any      qw{$log};
use Syntax::Keyword::Try;
use YAML::XS qw{LoadFile};

use BOM::Config;
use BOM::Database::ClientDB;
use BOM::Platform::S3Client;
use BOM::User;

GetOptions(
    'bucket_id=i' => \my $bucket_id,
    'workflow=s'  => \my $workflow
);

die "Usage: ./index_s3_user_file.pl --workflow=<workflow> --bucket_id=<bucket_id>"
    unless $bucket_id && $workflow && ($workflow eq 'desk' || $workflow eq 'zendesk-data');

my $config       = BOM::Config::s3()->{desk};
my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector'
    })->db->dbic;

my $email_userid_cache   = Cache::LRU->new(size => 10000);
my $filename_email_cache = Cache::LRU->new(size => 10000);

my $s3 = Amazon::S3->new({
    aws_access_key_id     => $config->{aws_access_key_id},
    aws_secret_access_key => $config->{aws_secret_access_key},
    retry                 => 3
});

my $s3_client = BOM::Platform::S3Client->new($config);

my $marker = get_last_processed_item();

desk_flow($marker)    if $workflow eq 'desk';
zendesk_flow($marker) if $workflow eq 'zendesk-data';

sub desk_flow {
    my $marker = shift;
    my ($current_prefix, $next_prefix);

    while (my $keys = list_bucket($marker, 'desk/case/')) {
        for my $key ($keys->{keys}->@*) {

            $current_prefix = get_path_prefix($key->{key}) unless $current_prefix;
            $next_prefix    = get_path_prefix($key->{key});

            # we are only concerned about the prefix.
            # list_bucket returns file names recursively.
            # we get (n) number of files with the same prefix.
            # we store the prefix only if the prefix changed.
            # or if it's the last key in the array to store the very last record.
            next if $current_prefix eq $next_prefix and $key->{key} ne $keys->{keys}->[-1]->{key};

            my $message_file = $current_prefix . "message.json";

            $log->debugf("starting to process $current_prefix");

            try {
                my $file_content = decode_json($s3_client->download($message_file)->get);
                my ($email_list, $customer_file_name) = get_user_email_list($message_file, $file_content);

                my $user_id;
                for my $email ($email_list->@*) {

                    my %file_names = (
                        $current_prefix => 0,
                        ($customer_file_name ? ($customer_file_name => 60) : ()));

                    $user_id = get_user_id($email);

                    save_path_into_db(\%file_names, $user_id) if $user_id;
                }

            } catch ($e) {
                $log->warnf("$e at $current_prefix");
            }

            $log->debugf("done processing $current_prefix");

            $current_prefix = $next_prefix;
        }

        # move the marker to start after the last entry.
        $marker = $keys->{keys}->[-1]->{key};
    }

    $filename_email_cache->clear();
}

sub get_user_email_list {
    my ($file_name, $file_content) = @_;

    my @customer_href      = split /\//, $file_content->{_links}->{customer}->{href};
    my $customer_file_name = "desk/customer/$customer_href[-1].json";

    my @email_list;

    try {
        @email_list = @{$filename_email_cache->get($customer_file_name)} if $filename_email_cache->get($customer_file_name);

        return \@email_list if scalar @email_list;

        my $customer_file_content = decode_json($s3_client->download($customer_file_name)->get);

        @email_list = map { $_->{value} } $customer_file_content->{emails}->@*;

        $filename_email_cache->set($customer_file_name => \@email_list);
    } catch ($e) {
        $log->warnf("Couldn't find file $customer_file_name") if $e =~ /404/;
        $log->warnf("ERROR: $e at $file_name")                if $e !~ /404/;
        return \@email_list;
    }

    return (\@email_list, $customer_file_name);
}

sub zendesk_flow {
    my $marker = shift;

    while (my $keys = list_bucket($marker, 'zendesk-data/tickets/')) {
        for my $key ($keys->{keys}->@*) {

            $log->debugf("starting to process $key->{key}");

            try {
                my $file_content = decode_json($s3_client->download($key->{key})->get);
                my $user_info    = $file_content->{requester};

                my $ticket_id = $file_content->{id};
                my $email     = $user_info->{email};
                my $user_id;

                unless ($email) {
                    my $loginid = $user_info->{user_fields}->{loginid} if $user_info->{user_fields};

                    my $client = BOM::User::Client->new(loginid => $loginid) if $loginid;

                    $user_id = $client->user->id if $client;
                }

                my %file_names = (
                    $key->{key} => 0,
                    map {
                        (map { $ticket_id . '_' . $_->{file_name} => 60 } $_->{attachments}->@*)
                    } $file_content->{comments}->@*
                );

                $user_id //= get_user_id($email);

                save_path_into_db(\%file_names, $user_id) if $user_id;

            } catch ($e) {
                $log->warnf("$e at $key->{key}");
            }

            $log->debugf("done processing $key->{key}");
        }

        # move the marker to start after the last entry.
        $marker = $keys->{keys}->[-1]->{key};
    }
}

sub get_user_id {
    my $email = shift;

    die "Email is required" unless $email;

    my $user_id = $email_userid_cache->get($email);

    die "user not found for: $email" if $user_id && $user_id == -1;

    return $user_id if $user_id;

    my $user = BOM::User->new(email => $email);

    unless ($user) {
        $email_userid_cache->set($email => -1);
        die "user not found for: $email";
    }

    $user_id = $user->id;
    $email_userid_cache->set($email => $user_id);

    return $user_id;
}

sub save_path_into_db {
    my ($file_names, $user_id) = @_;

    # we parse one file and extract different files from different locations
    # we use this file_name as reference to where have we stopped
    # we store this file_name with the current timestamp. other files with earlier timestamp
    # since we order by created_at in get_workflow_marker we will be able to extact the latest file_name we need.

    my $query = 'INSERT INTO data_collection.s3_user_file VALUES' . join ',', map { '(?, ?, ?, NOW() - ?::interval)' } keys $file_names->%*;

    my @params = map { ($bucket_id, $user_id, $_, "$file_names->{$_}m") } keys $file_names->%*;

    $collector_db->run(
        ping => sub {
            $_->do($query, undef, @params);
        });
}

sub get_last_processed_item {
    my $result = $collector_db->run(
        ping => sub {
            $_->selectrow_array('SELECT path FROM data_collection.s3_user_file where bucket_id = ? AND path LIKE ? ORDER BY created_at DESC LIMIT 1',
                {}, $bucket_id, "$workflow%");
        });

    return '' unless $result;

    my $keys   = list_bucket('', $result);
    my $marker = $keys->{keys}->[-1]->{key};

    return $marker;
}

sub list_bucket {
    my ($marker, $prefix) = @_;

    return $s3->list_bucket({
        bucket     => $config->{aws_bucket},
        prefix     => $prefix,
        'max-keys' => 10000,
        marker     => $marker,
    });
}

sub get_path_prefix {
    my $path = shift;

    # this is to extract prefix for one file
    # for desk/case/X/filename.extension we need to store desk/case/X/.
    $path =~ s/^(?:\w+\/){3}\K.*$// or die 'invalid path found - ' . $path;

    return $path;
}
