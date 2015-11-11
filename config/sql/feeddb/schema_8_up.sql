BEGIN;
CREATE OR REPLACE PROCEDURAL LANGUAGE plperl;

CREATE TABLE feed.realtime_ohlc (
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

CREATE OR REPLACE FUNCTION tick_notify(VARCHAR(128),BIGINT,DOUBLE PRECISION) RETURNS TEXT AS
$tick_notify$
    my $underlying      = $_[0];
    my $ts              = $_[1];
    my $spot            = $_[2];
    my $time_adjustment = 0;
    my @grans           = qw(60 120 300 600 900 1800 3600 7200 14400 28800 86400);

    $rv = spi_exec_query("SELECT * FROM feed.realtime_ohlc where underlying='$underlying'", 1);

    $openclose = spi_exec_query("SELECT * FROM feed.underlying_open_close where underlying='$underlying'", 1);
    $time_adjustment = $openclose->{rows}[0]->{open_time} if $openclose->{rows}[0]->{open_time};

    $ohlc_val = '';
    if (!$rv->{rows}[0]->{ohlc}) {
        $all_same = "$spot,$spot,$spot,$spot";
        foreach (@grans) { $ohlc_val .= "$_:$all_same;" }
        $rv = spi_exec_query("INSERT INTO feed.realtime_ohlc VALUES ('$underlying', $ts, '$ohlc_val')");
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
        $rv = spi_exec_query("UPDATE feed.realtime_ohlc SET ts=$ts, ohlc='$ohlc_val' where underlying='$underlying'");
        $rv = spi_exec_query("SELECT pg_notify('feed_watchers', '$underlying;$ts;$spot;$ohlc_val');");
    }

  return $ohlc_val;
$tick_notify$
LANGUAGE 'plperl';

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON ALL TABLES IN SCHEMA feed TO write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed TO write;
COMMIT;
