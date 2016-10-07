#!/etc/rmg/bin/perl
use strict;
use warnings;
use 5.010;
use YAML::XS;
use DBI;
use DBD::Pg;
use IO::Select;
use Try::Tiny;
use Postgres::FeedDB;

use BOM::MarketData qw(create_underlying_db);
use Finance::Asset::Market::Registry;
use BOM::System::RedisReplicated;

update_crossing_underlyings();
while (1) {
    try {
        my $dbh   = Postgres::FeedDB::write_dbh();

        my $MAX_FEED_CHANNELS = 80;
        $dbh->do("LISTEN feed_watchers_$_") for (1..$MAX_FEED_CHANNELS);

        my $sel = IO::Select->new;
        $sel->add($dbh->{pg_socket});
        while ($sel->can_read) {
            while (my $notify = $dbh->pg_notifies) {
                my ($name, $pid, $payload) = @$notify;
                _publish($payload);
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
    my $payload = shift;
    my @data    = split(';', $payload);

    BOM::System::RedisReplicated::redis_write->publish('FEED::' . $data[0], $payload);
}

sub update_crossing_underlyings {
    my @all_symbols = create_underlying_db->get_symbols_for(
        market            => [Finance::Asset::Market::Registry->instance->all_market_names],
        contract_category => 'ANY'
    );
    my $update = '';
    foreach my $s (@all_symbols) {
        my $u = create_underlying($s);
        if ($u->calendar->market_times()->{standard}->{daily_open}->seconds < 0) {
            $update .=
                  "INSERT INTO feed.underlying_open_close VALUES ('$s', "
                . $u->calendar->market_times()->{standard}->{daily_open}->seconds . ", "
                . $u->calendar->market_times()->{standard}->{daily_close}->seconds . ");";
        }
    }
    Postgres::FeedDB::write_dbh()->do("
        BEGIN;
        DELETE FROM feed.underlying_open_close;
        $update
        COMMIT;
    ");
}
