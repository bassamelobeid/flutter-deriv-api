#!/etc/rmg/bin/perl
use strict;
use warnings;

use Syntax::Keyword::Try;
use Getopt::Long;
use Log::Any::Adapter;
use Log::Any qw($log);
use BOM::Database::ClientDB;
use BOM::Config::Runtime;

GetOptions(
    'l|log_level=s' => \my $log_level,
);

Log::Any::Adapter->import(qw(DERIV), log_level => $log_level // 'info');

my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
    })->db->dbic;

my $brokers = $collector_db->run(
    fixup => sub {
        $_->selectcol_arrayref('SELECT UPPER(srvname) FROM betonmarkets.production_servers()');
    });

my $days = BOM::Config::Runtime->instance->app_config->payments->reversible_deposits_lookback;

for my $broker (@$brokers) {
    $log->debugf('Processing %s', $broker);

    try {
        my $db = BOM::Database::ClientDB->new({
                broker_code => $broker,
            })->db->dbic;

        $db->run(
            fixup => sub {
                $_->do('SELECT payment.doughflow_method_populate(?,?)', undef, $broker, $days);
            });
    } catch ($e) {
        $log->errorf('Error processing %s: %s', $broker, $e);
        next;
    }
    $log->debugf('Processing %s done', $broker);
}
