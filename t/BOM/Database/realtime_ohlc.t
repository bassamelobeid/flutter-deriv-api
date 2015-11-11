#!/usr/bin/perl
use strict;
use warnings;

use Test::More qw/tests 13/;
use Test::Deep;
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);


my $dbh = BOM::Database::FeedDB::write_dbh();

my $p = "1.1,1.1,1.1,1.1";
$dbh->do("SELECT tick_notify('TEST', 1, CAST(1.1 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>1, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"}, "Normal");

$p = "1.1,1.2,1.1,1.2";
$dbh->do("SELECT tick_notify('TEST', 2, CAST(1.2 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>2, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"});

$p = "1.1,1.2,0.9,0.9";
$dbh->do("SELECT tick_notify('TEST', 3, CAST(0.9 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>3, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"});

$p = "1.1,1.5,0.9,1.5";
$dbh->do("SELECT tick_notify('TEST', 61, CAST(1.5 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>61, ohlc=>"60:1.5,1.5,1.5,1.5;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"});

$p = "1.1,1.6,0.9,1.6";
$dbh->do("SELECT tick_notify('TEST', 121, CAST(1.6 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>121, ohlc=>"60:1.6,1.6,1.6,1.6;120:1.6,1.6,1.6,1.6;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"});

$p = "2.1,2.1,2.1,2.1";
$dbh->do("SELECT tick_notify('TEST', 86400-3600-10, CAST(2.1 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>86400-3600-10, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:1.1,2.1,0.9,2.1;"});

$p = "2.3,2.3,2.3,2.3";
$dbh->do("SELECT tick_notify('TEST', 86400-3600+10, CAST(2.3 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>86400-3600+10, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:2.1,2.3,2.1,2.3;14400:2.1,2.3,2.1,2.3;28800:2.1,2.3,2.1,2.3;86400:1.1,2.3,0.9,2.3;"});

$p = "0.6,0.6,0.6,0.6";
$dbh->do("SELECT tick_notify('TEST', 86400+1, CAST(0.6 as DOUBLE PRECISION))");
cmp_deeply(_r('TEST'), {underlying=>'TEST', ts=>86400+1, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"});



# Now checking an imaginary market that open -1H UTC
$dbh->do("INSERT INTO feed.underlying_open_close VALUES('EARLY', -3600, 14400);");

my $start = 86400-3600;

$p = "1.1,1.1,1.1,1.1";
$dbh->do("SELECT tick_notify('EARLY', $start-10, CAST(1.1 as DOUBLE PRECISION))");
cmp_deeply(_r('EARLY'), {underlying=>'EARLY', ts=>$start-10, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"}, "Eraly open");

$p = "1.5,1.5,1.5,1.5";
$dbh->do("SELECT tick_notify('EARLY', 86400-3600+11, CAST(1.5 as DOUBLE PRECISION))");
cmp_deeply(_r('EARLY'), {underlying=>'EARLY', ts=>$start+11, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"}, "A new day starts even before UTC day");

$p = "1.6,1.6,1.6,1.6";
$dbh->do("SELECT tick_notify('EARLY', $start+3600, CAST(1.6 as DOUBLE PRECISION))");
cmp_deeply(_r('EARLY'), {underlying=>'EARLY', ts=>$start+3600, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:1.5,1.6,1.5,1.6;14400:1.5,1.6,1.5,1.6;28800:1.5,1.6,1.5,1.6;86400:1.5,1.6,1.5,1.6;"}, "Still the same day at zero time");

$p = "1.8,1.8,1.8,1.8";
$dbh->do("SELECT tick_notify('EARLY', $start+3600*9, CAST(1.8 as DOUBLE PRECISION))");
cmp_deeply(_r('EARLY'), {underlying=>'EARLY', ts=>$start+3600*9, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:1.5,1.8,1.5,1.8;"}, "Almost end of the day");

$p = "1.9,1.9,1.9,1.9";
$dbh->do("SELECT tick_notify('EARLY', $start+3600*24, CAST(1.9 as DOUBLE PRECISION))");
cmp_deeply(_r('EARLY'), {underlying=>'EARLY', ts=>$start+3600*24, ohlc=>"60:$p;120:$p;300:$p;600:$p;900:$p;1800:$p;3600:$p;7200:$p;14400:$p;28800:$p;86400:$p;"}, "And the next day start again before next UTC day");


sub _r {
    my $s = shift;
    return $dbh->selectrow_hashref("SELECT * FROM feed.realtime_ohlc WHERE underlying='$s'");
}
done_testing;
