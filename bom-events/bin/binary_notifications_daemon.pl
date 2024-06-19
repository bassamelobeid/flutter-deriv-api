#!/etc/rmg/bin/perl
use strict;
use warnings;

use Log::Any    qw($log);
use Time::HiRes qw(time sleep);
use DateTime;
use Getopt::Long;
use BOM::Config::Redis;
use BOM::Event::NotificationsService;

require Log::Any::Adapter;

GetOptions(
    'l|log=s'         => \my $log_level,
    'json_log_file=s' => \my $json_log_file,
) or die;

$log_level     ||= 'info';
$json_log_file ||= '/var/log/deriv/' . path($0)->basename . '.json.log';

Log::Any::Adapter->import(
    qw(DERIV),
    log_level     => $log_level,
    json_log_file => $json_log_file
);

sub _daemon_run {
    my $notifications_service = BOM::Event::NotificationsService->new(redis => BOM::Config::Redis::redis_expiryq_write);

    while (1) {
        my $start = time;
        my $next  = int($start + 1);
        $notifications_service->dequeue_notifications();
        $notifications_service->dequeue_dc_notifications();
        my $remaining = $next - time;
        # well, you don't want this process to be polling from redis a gazillion times every second
        sleep($remaining) if ($remaining > 0);
    }
}

_daemon_run();
