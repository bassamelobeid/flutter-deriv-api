#!/etc/rmg/bin/perl

# This file is for deletion of existing 'INTERNAL::TRANSFER::FIAT::CRYPTO::USER::*' keys in the redis
# The records will be useless as the latest changes will take the data from db directly

use strict;
use warnings;

use Getopt::Long;
use Log::Any qw($log);
use Data::Dumper;
use BOM::Config::Redis;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

require Log::Any::Adapter;
GetOptions(
    'l|log=s'  => \my $log_level,
    'd|dryrun' => \my $dry_run_flag,
) or die;

$log_level    ||= 'info';
$dry_run_flag ||= 0;
Log::Any::Adapter->import(qw(DERIV), log_level => $log_level);

$log->infof("Start script with setings: %s , %s \n", $log_level, $dry_run_flag);

my $redis = BOM::Config::Redis::redis_replicated_write();

my $all_keys = $redis->keys('INTERNAL::TRANSFER::FIAT::CRYPTO::USER::*');

sub show_all_keys {

    $log->warnf("KEYS TO REMOVE: %s", $all_keys);

    return undef;
}

sub delete_all_keys {

    for my $each_key (@$all_keys) {
        $redis->del($each_key);
    }

    $log->infof("Deleted all internal transfer redis record");

    return undef;
}

$dry_run_flag ? show_all_keys() : delete_all_keys();

$log->infof('Script ran successfully');

1;
