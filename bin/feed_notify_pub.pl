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
use BOM::MarketData qw(create_underlying);
use Finance::Asset::Market::Registry;
use BOM::Platform::RedisReplicated;

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
    my ($symbol, $epoch, @quotes) = split(';', $payload);

    BOM::Platform::RedisReplicated::redis_write->publish('FEED::' . $symbol,
        join(';', $symbol, $epoch, pip_size($symbol, @quotes))
    );
}

sub pip_size {
    my ($symbol, @quotes) = @_;

    my @pip_sized_quotes;
    my $underlying = create_underlying($symbol);
    push @pip_sized_quotes, $underlying->pipsized_value(shift @quotes);
    push @pip_sized_quotes, pip_size_ohlc($underlying, @quotes);

    return @pip_sized_quotes;
}

sub pip_size_ohlc {
    my ($underlying, @ohlc) = @_;
    
    my @pip_sized_quotes;
    for (@ohlc) {
        my ($type, @ohlc) = grep{defined} (/(\d+:)([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+)/);
        if (@ohlc != 4) {
            warn("OHLC data should has 4 quotes: $_");
        }
        else {
            push @pip_sized_quotes, $type. join(',', map {$underlying->pipsized_value($_)} @ohlc);
        }
    }
    return @pip_sized_quotes;
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
