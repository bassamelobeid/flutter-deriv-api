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
    PRIMARY KEY (underlyings)
);

-- underlying VARCHAR(128),ts EPOCH, spot DOUBLE PRECISION
CREATE OR REPLACE FUNCTION tick_notify(VARCHAR(128),BIGINT,DOUBLE PRECISION) RETURNS TEXT AS
$tick_notify$
  my $underlying = $_[0];
  my $ts = $_[1];
  my $spot = $_[2];
  my @grans = qw(60 120 300 600 900 1800 3600 7200 14400 28800 86400);

  # Get the only record which should exist for each underlying
  $rv = spi_exec_query("SELECT * FROM feed.realtime_ohlc where underlying='$underlying'", 1);

  # dealing with those markets that their open and close is not in the same UTC period.
  $openclose = spi_exec_query("SELECT * FROM feed.underlying_open_close where underlying='$underlying'", 1);
  $ts += $openclose->{rows}[0]->{open_time} if $openclose->{rows}[0]->{open_time};


  # If there is no then record insert one.
  if (!$rv->{rows}[0]->{ohlc}) {
    $all_same = "$spot,$spot,$spot,$spot";
    $ohlc_val='';
    foreach (@grans) {$ohlc_val .= "$_:$all_same;"}
    $rv = spi_exec_query("INSERT INTO feed.realtime_ohlc VALUES ('$underlying', $ts, '$ohlc_val')");
  # If there is any record update it for each granuality
  } else {
    # Find array of all ohlc values saved in ohlc field in text type
    $N = '([.0-9+-]+),([.0-9+-]+),([.0-9+-]+),([.0-9+-]+)';
    $pattern = "";
    foreach (@grans) {$pattern .= "$_:$N;"}
    @match = ($rv->{rows}[0]->{ohlc} =~ /$pattern/g);

    # convert the array to hash to using it a bit less error prone
    my $m;
    $c=0;
    foreach (@grans) {$m->{"o_$_"}=$match[$c];$c++;$m->{"h_$_"}=$match[$c];$c++;$m->{"l_$_"}=$match[$c];$c++;$m->{"c_$_"}=$match[$c];$c++;}

    # go through all granualities and update them
    $ohlc_val='';
    foreach $g (@grans) {
      # if last ohlc ts is still in same time period of new tick ts for that granuality
      if (($ts - $ts % $g) == ($rv->{rows}[0]->{ts} - $rv->{rows}[0]->{ts} % $g)) {
        $ohlc_val.="$g:".$m->{"o_$g"}.",";
        $ohlc_val.=($spot>$m->{"h_$g"})? "$spot,":$m->{"h_$g"}.",";
        $ohlc_val.=($spot<$m->{"l_$g"})? "$spot,":$m->{"l_$g"}.",";
        $ohlc_val.="$spot;";
      # if this is a new period reset all ohlc values for that period
      } else {
        $ohlc_val.="$g:$spot,$spot,$spot,$spot;";
      }
    }
    $rv = spi_exec_query("UPDATE feed.realtime_ohlc SET ts=$ts, ohlc='$ohlc_val' where underlying='$underlying'");
    $rv = spi_exec_query("SELECT pg_notify('feed_watchers', '$ts;$spot;$ohlc_val');");
  }

return $ohlc_val;
$tick_notify$
LANGUAGE 'plperl';

GRANT SELECT, INSERT, UPDATE, DELETE, TRIGGER ON ALL TABLES IN SCHEMA feed TO write;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA feed TO write;
COMMIT;
