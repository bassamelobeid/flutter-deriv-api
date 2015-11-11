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
        $pattern = "";
        foreach (@grans) { $pattern .= "$_:([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+);" }
        @match = ($rv->{rows}[0]->{ohlc} =~ /$pattern/g);

        my $m;
        $c = 0;
        foreach (@grans) {
            $m->{"o_$_"} = $match[$c];
            $m->{"h_$_"} = $match[$c+1];
            $m->{"l_$_"} = $match[$c+2];
            $m->{"c_$_"} = $match[$c+3];
            $c+=4;
        }

        foreach $g (@grans) {
            # Shitfing the record TS with time_adjustment for cross UTC day markets
            if (($ts  - $time_adjustment - ($ts - $time_adjustment) % $g) == ($rv->{rows}[0]->{ts} - $rv->{rows}[0]->{ts} % $g)) {
                $ohlc_val .= "$g:" . $m->{"o_$g"} . ",";
                $ohlc_val .= ($spot > $m->{"h_$g"}) ? "$spot," : $m->{"h_$g"} . ",";
                $ohlc_val .= ($spot < $m->{"l_$g"}) ? "$spot," : $m->{"l_$g"} . ",";
                $ohlc_val .= "$spot;";
            } else {
                $ohlc_val .= "$g:$spot,$spot,$spot,$spot;";
            }
        }
        $rv = spi_exec_query("UPDATE feed.realtime_ohlc SET ts=$ts, ohlc='$ohlc_val' where underlying='$underlying'");
        $rv = spi_exec_query("SELECT pg_notify('feed_watchers', '$underlying:$ts;$spot;$ohlc_val');");
    }

  return $ohlc_val;
$tick_notify$
LANGUAGE 'plperl';

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON ALL TABLES IN SCHEMA feed TO write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed TO write;
COMMIT;
