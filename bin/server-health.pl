#!/usr/bin/env perl 
use strict;
use warnings;

=head1 NAME

C<server-health.pl>

=head1 DESCRIPTION

Generates Redis statistics for server health.

Currently this includes:

=over 4

=item * whether the Chrony NTP service is active

=item * current server time

=item * smallest amount of available space on all C</dev> mountpoints

=back

Data is stored under C<< server::hostname >> as a hash with expiry set to
twice the interval by default.

=cut

no indirect;
use List::Util qw(min);
use IO::Async::Loop;
use Ryu::Async;
use Net::Async::Redis;
use Time::HiRes;
use Sys::Hostname;

use DataDog::DogStatsd::Helper qw(stats_gauge);

use Log::Any qw($log);
use Log::Any::Adapter qw(Stdout), log_level => 'info';

use Getopt::Long qw(GetOptions);

GetOptions(
    'interval|i=i'   => \my $interval,
    'redis|r=s'      => \my $redis_uri,
    'name|n=s'       => \my $name,
    'redis-auth|a=s' => \my $redis_auth,
);

($name) = Sys::Hostname::hostname() =~ /^([^.]+)/ unless $name;
$interval   //= 60;
$redis_uri  //= 'redis://localhost';
$redis_auth //= '';

# Prepare and connect to Redis
my $loop = IO::Async::Loop->new;
$loop->add(
    my $redis = Net::Async::Redis->new(
        uri  => $redis_uri,
        auth => $redis_auth,
    ));
$loop->add(my $ryu = Ryu::Async->new);
$redis->connect->get;

# Start main loop
$log->infof('Server health check main loop active for %s, interval %d seconds', $name, $interval);
$ryu->timer(interval => $interval)
    # Generate the statistics
    ->map(
    sub {
        my %stats;
        $stats{now} = Time::HiRes::time;

        # Later can try Net::NTP to verify whether it's responding
        $stats{found_ntp} = qx{pgrep chronyd} =~ /\d+/ ? 1 : 0;

        my $df_check = sub {
            # Options are passed directly to `df`, typically would be '-i' for inodes, '-m' for megabytes
            my ($options) = @_;

            chomp(my @disk_free = qx{df $options});
            # Skip the header
            shift @disk_free;
            my $free;
            for my $line (@disk_free) {
                my ($dev, $total, $used, $available, $percent, $mountpoint) = split ' ', $line;
                # Only want 'real' mountpoints - if there's some sort of device involved, it's
                # probably relevant. Explicitly filter out /boot even though it's usually not mounted.
                next unless $dev =~ m{^/dev/} or $dev =~ m{\b/boot};
                $free = min $available, $free // ();
            }
            $free;
        };

        # Total service uptime is not measured in seconds
        $stats{uptime_valid} = qx{uptime} !~ /sec/ ? 1 : 0;

        # Minimum spare space in MB across all non-tmpfs mountpoints
        $stats{disk_free} = $df_check->('-m');
        # Minimum available inodes across all non-tmpfs mountpoints
        $stats{inodes_free} = $df_check->('-i');
        $stats{healthy}     = (
            # At least 1G free on all drives
            $stats{disk_free} > 1024
                # and 1k inodes
                && $stats{inodes_free} > 1024
                # and NTP should be running
                && $stats{found_ntp}
                && $stats{uptime_valid}) ? 1 : 0;
        return \%stats;
    })
    # Apply them to Redis
    ->each(
    sub {
        my %data = %$_;
        my $k    = 'server_health::' . $name;
        $log->debugf('Recording %s for %s', \%data, $k);
        stats_gauge('server.health.' . $_, $data{$_}, {tags => ["name:$name"]}) for sort keys %data;
        $redis->hmset($k => %data)->on_done(sub { $log->debugf('Recorded row data %s', \%data) })
            ->on_fail(sub { $log->errorf('failed to record server status info - %s', $_[0]) })->then(
            sub {
                # Use slightly more than our interval value for expiry, so we don't drop the
                # data too early on service restart or slow queries.
                $redis->expire($k => 300 + $interval);
            })->retain;
    })->await;
$log->infof('Server health check loop shutting down');

__END__


