#!/etc/rmg/bin/perl

use strict;
use warnings;

use Digest::MD5;
use List::MoreUtils qw(uniq);
use Path::Tiny qw(path);
use POSIX qw(strftime);

use BOM::Config::RedisReplicated;

use constant EXPORT_PATH => '/var/lib/binary/pricing-metrics';

=head1 NAME

price_metrics

=head1 DESCRIPTION

Takes a snapshot of price metrics stored in redis at the end of every minute,
and export the result as a C<CSV> file for the last minute.

This script is being called by a cron job that runs every minute.

=cut

export_last_minute();

sub export_last_minute {
    mkdir EXPORT_PATH unless (-d EXPORT_PATH);

    my $file_path = path(EXPORT_PATH, strftime("%Y-%m-%d_%H-%M", gmtime) . '.csv');

    $file_path->spew_utf8(generate_csv_contents());
}

sub generate_csv_contents {
    my $redis_pricer = BOM::Config::RedisReplicated::redis_pricer();

    $redis_pricer->multi;

    $redis_pricer->hgetall('PRICE_METRICS::COUNT');
    $redis_pricer->hgetall('PRICE_METRICS::TIMING');
    $redis_pricer->hgetall('PRICE_METRICS::QUEUED');
    $redis_pricer->del('PRICE_METRICS::COUNT');
    $redis_pricer->del('PRICE_METRICS::TIMING');
    $redis_pricer->del('PRICE_METRICS::QUEUED');

    my $result = $redis_pricer->exec;

    my @results = map { {@$_} } grep { ref $_ eq 'ARRAY' } $result->@*;
    my @unique_shortcodes = sort { $a cmp $b } uniq map { keys $_->%* } @results;

    my $csv_contents = (join ',', qw(shortcode processed timing queued)) . "\n";

    for my $shortcode (@unique_shortcodes) {
        $csv_contents .= (join ',', ($shortcode, map { $_->{$shortcode} // '' } @results)) . "\n";
    }

    return $csv_contents;
}
