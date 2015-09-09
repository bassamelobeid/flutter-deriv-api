#!/usr/bin/perl
package main;

use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use HTML::Entities;
use f_brokerincludeall;
use BOM::Market::UnderlyingDB;
use BOM::Market::Registry;
use Proc::Killall;
use BOM::Market::Registry;
use Feed::Listener::Quote;
use Try::Tiny;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation('REALTIME QUOTES');
my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access(['Quants']);

my @all_markets = BOM::Market::Registry->instance->all_market_names;
push @all_markets, 'futures';    # this is added to check for futures feed
my $feedloc = BOM::Platform::Runtime->instance->app_config->system->directory->feed;
my $dbloc   = BOM::Platform::Runtime->instance->app_config->system->directory->db;
my $tmp_dir = BOM::Platform::Runtime->instance->app_config->system->directory->tmp;

my $now          = Date::Utility->new;
my @providerlist = qw(idata random telekurs sd tenfore bloomberg olsen test combined);

Bar("Compare providers");

#colors help
print "<UL>COLORS USED:<LI><font color=FF8888>Over 180 seconds</font>";
print "<LI><font color=F0F0F0>Shadow tick file</font>";
print "<LI><font color=F09999>Shadow tick file over 180 seconds</font>";
print "<LI><font color=FF0000>More than 0.2\% away from combined quote (0.4\% for stocks)</font>";
print "</UL>";

my @instrumentlist = sort BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market => [@all_markets],
);

print " &nbsp;-&nbsp; <a href='"
    . request()->url_for(
    "backoffice/f_rtquoteslogin.cgi",
    {
        broker => $broker,
        what   => "all"
    }) . "'>ALL (even mkt closed)</a>";

print "<table border=1 cellpadding=1 cellspacing=1>";
print "<tr><td bgcolor=FFFFCE>* bets offered</td>";
foreach my $p (@providerlist) { print "<td bgcolor=FFFFCE><b>" . uc($p) . "</td>"; }
print "</tr>";

my $all = request()->param('what');
foreach my $i (@instrumentlist) {

    my $underlying = BOM::Market::Underlying->new($i);

    my $realexchange = $underlying->exchange;
    next unless $all or $realexchange->is_open;

    my $MAXDIFF = 0.002;
    if ($underlying->instrument_type eq 'individualstock') { $MAXDIFF = 0.004; }    #stocks are more volatile

    print "<tr><td bgcolor=FFFFCE>";
    print "<a target=$i href=\""
        . request()->url_for(
        'backoffice/rtquotes_displayallgraphs.cgi',
        {
            overlay      => $i,
            all_provider => 1
        }) . "\">$i</a></b>";
    print "&nbsp; <a target=y$i href=\""
        . request()->url_for(
        'backoffice/rtquotes_displayallgraphs.cgi',
        {
            overlay      => $i,
            all_provider => 1,
            yday         => 1
        }) . "\">yday</a></td>";
    my $currtime = time;

    foreach my $p (@providerlist) {
        my ($tick, $price, $timestamp);

        # For combined folder, we need to look up the correct combined folder.
        if ($p eq 'combined') {
            $tick      = $underlying->get_combined_realtime;
            $timestamp = $tick->{epoch};
            $price     = $tick->{quote};
        } else {
            my $quote = try { Cache::RedisDB->get('PROVIDER_LAST_QUOTE', "$p/" . $underlying->symbol) };
            ($timestamp, $price) = ($quote->epoch, $quote->price) if $quote and ref $quote eq 'Feed::Listener::Quote';
        }
        unless (defined $timestamp and defined $price) {
            print "<td bgcolor=#FFFFCE>&nbsp;</td>";
            next;
        }

        my $age = $currtime - $timestamp;

        if ($age > 86400 * 4) { print "<td bgcolor=#FFFFCE>&nbsp;</td>"; }
        elsif ($p ne 'combined' and $age > 180) { print "<td bgcolor=#F09999><i>$price</i><br><i>$age secs.</i></td>"; }
        elsif ($p ne 'combined') { print "<td bgcolor=#F0F0F0><i>$price</i><br><i>$age secs.</i></td>"; }
        elsif ($age > 180)       { print "<td bgcolor=FF8888>$price<br><b>$age secs.</b></td>"; }
        else {
            #compare it to combined feed
            my $spot = $underlying->spot;
            if (abs($spot - $price) > abs($price) * $MAXDIFF)    #0.2% diff
            {
                print "<td bgcolor=#FF0000>!$price!<br>TS $age secs</td>";
            } else {
                print "<td bgcolor=white>$price<br>TS $age secs</td>";
            }
        }
    }

    print "<td>";

    my $mkt = $underlying->market->name;
    if ($mkt ne 'config') {
        # display all providers for this market
        print join ", ", @{$underlying->market->providers};
    }
    print "</td>";
    print "</tr>";
}

print "</table><P>";

code_exit_BO();
