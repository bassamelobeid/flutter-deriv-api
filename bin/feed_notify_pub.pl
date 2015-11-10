#!/usr/bin/perl
use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Try::Tiny;
use RedisDB;
use BOM::Database::FeedDB;

use BOM::Market::UnderlyingDB;
use BOM::Market::Registry;


update_crossing_underlyings()
while (1) {
    try {
        my $redis = _redis();
        my $dbh   = BOM::Database::FeedDB::write_dbh();

        $dbh->do("LISTEN feed_watchers");

        my $sel = IO::Select->new;
        $sel->add($dbh->{pg_socket});
        while ($sel->can_read) {
            while (my $notify = $dbh->pg_notifies) {
                my ($name, $pid, $payload) = @$notify;
                _publish($redis, $payload);
            }
        }
    }
    catch {
        warn "$0 ($$): saw exception: $_";
        sleep 1;
    };
}
exit;

sub _publish {
    my $redis     = shift;
    my $payload   = shift;
    my @data      = split(';', $payload);

    $redis->publish('FEED::' . $data[0], $payload);

}

sub _redis {
    my $config = YAML::XS::LoadFile('/etc/rmg/chronicle.yml');
    return RedisDB->new(
        host     => $config->{write}->{host},
        port     => $config->{write}->{port},
        password => $config->{write}->{password});
}

sub update_crossing_underlyings {
    my @all_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
            market            => [BOM::Market::Registry->instance->all_market_names],
            contract_category => 'ANY'
        );
    my $update = '';
    foreach $s (@all_symbols) {
        $u = BOM::Market::Underlying->new($s);
        if ($u->exchange->market_times()->{standard}->{daily_open}->seconds<0) {
            $update .= "INSERT INTO feed.underlying_open_close VALEUS ('$s', ".$u->exchange->market_times()->{standard}->{daily_open}->seconds.", ".$u->exchange->market_times()->{standard}->{daily_close}->seconds.");";
        }
    }
    BOM::Database::FeedDB::write_dbh()->do("
        BEGIN;
        DELETE FROM feed.underlying_open_close;
        $update
        COMMIT;
    ");
}
