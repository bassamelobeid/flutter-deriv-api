BEGIN;
CREATE OR REPLACE PROCEDURAL LANGUAGE plperl;

CREATE TABLE feed.realtime_ohlc (
    id serial,
    underlying VARCHAR(128) NOT NULL,
    ts BIGINT NOT NULL,
    ohlc TEXT NOT NULL,
    PRIMARY KEY (underlying)
);

CREATE TABLE feed.underlying_open_close (
    underlying VARCHAR(128) NOT NULL,
    open_time BIGINT NOT NULL,
    close_time TEXT NOT NULL,
    PRIMARY KEY (underlying)
);

-- This is just to set if notification must be sent or not.
-- in case of accumulation of ticks system might have issue seding thoushands of notifications
-- in a short period.
CREATE TABLE feed.do_notify (
    do_notify BOOLEAN DEFAULT 'true'
);

INSERT INTO feed.do_notify VALUES (true);

CREATE OR REPLACE FUNCTION tick_notify(VARCHAR(128),BIGINT,DOUBLE PRECISION) RETURNS TEXT AS
$tick_notify$
    my $underlying           = $_[0];
    my $ts                   = $_[1];
    my $spot                 = $_[2];
    my $time_adjustment      = 0;
    my @grans                = qw(60 120 180 300 600 900 1800 3600 7200 14400 28800 86400);
    my $MAX_FEED_CHANNELS    = 80; # Listener must listen to all these.

    $fake = spi_exec_query("SELECT current_setting('feed.fake_aggretation_tick')::BOOLEAN", 1);
    if ($fake->{rows}[0]->{current_setting}) {
        return;
    }

    $rv = spi_exec_query("SELECT * FROM feed.realtime_ohlc where underlying='$underlying'", 1);

    $openclose = spi_exec_query("SELECT * FROM feed.underlying_open_close where underlying='$underlying'", 1);
    $time_adjustment = $openclose->{rows}[0]->{open_time} if $openclose->{rows}[0]->{open_time};

    $ohlc_val = '';
    if (!$rv->{rows}[0]->{ohlc}) {
        $all_same = "$spot,$spot,$spot,$spot";
        foreach (@grans) { $ohlc_val .= "$_:$all_same;" }
        spi_exec_query("INSERT INTO feed.realtime_ohlc VALUES (DEFAULT, '$underlying', $ts, '$ohlc_val')");
        $rv = spi_exec_query("SELECT * FROM feed.realtime_ohlc where underlying='$underlying'", 1);
    } else {
        foreach $g (@grans) {
            my $pattern = "$g:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);";
            @match = ($rv->{rows}[0]->{ohlc} =~ /$pattern/g);
            # Shitfing the record TS with time_adjustment for cross UTC day markets
            if (scalar @match>0 and ($ts  - $time_adjustment - ($ts - $time_adjustment) % $g) == ($rv->{rows}[0]->{ts} - $time_adjustment - ($rv->{rows}[0]->{ts} -$time_adjustment) % $g)) {
                $ohlc_val .= "$g:" . $match[0] . ",";
                $ohlc_val .= ($spot > $match[1]) ? "$spot," : $match[1] . ",";
                $ohlc_val .= ($spot < $match[2]) ? "$spot," : $match[2] . ",";
                $ohlc_val .= "$spot;";
            } else {
                $ohlc_val .= "$g:$spot,$spot,$spot,$spot;";
            }
        }
        spi_exec_query("UPDATE feed.realtime_ohlc SET ts=$ts, ohlc='$ohlc_val' where underlying='$underlying'");
        if (spi_exec_query("SELECT do_notify FROM feed.do_notify", 1)->{rows}[0]->{do_notify} eq 't') {
            $rv = spi_exec_query("SELECT pg_notify('feed_watchers_". ($rv->{rows}[0]->{id} % $MAX_FEED_CHANNELS + 1) ."', '$underlying;$ts;$spot;$ohlc_val');");
        }
    }

  return $ohlc_val;
$tick_notify$
LANGUAGE 'plperl';

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON ALL TABLES IN SCHEMA feed TO write;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA feed TO write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed TO write;
COMMIT;
