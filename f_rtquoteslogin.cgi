#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];

use HTML::Entities;
use f_brokerincludeall;
use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use Finance::Asset::Market::Registry;
use Proc::Killall;
use Try::Tiny;
use Path::Tiny;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Sysinit ();
use File::ReadBackwards;
use Date::Utility;
use List::Util qw/reduce/;

BOM::Backoffice::Sysinit::init();
$Quant::Framework::Underlying::FORCE_REALTIME_FEED = 1;

my $fullfeed_re = qr/^\d\d?-\w{3}-\d\d.fullfeed(?!\.zip)/;

my $_quotes_cache;

sub last_quote {
    my $dir = shift;

    # check in cache
    return @{$_quotes_cache->{$dir}} if $_quotes_cache->{$dir};

    my $recent = reduce { $a->[1] < $b->[1] ? $a : $b } map { [$_, -M $_] } $dir->children($fullfeed_re);
    $recent = $recent->[0] // die("Cannot find last quote file in $dir");
    my $bw = File::ReadBackwards->new($recent)
        or die "can't read $recent: $!";

    my $line = $bw->readline;
    # fill cache
    $_quotes_cache->{$dir} = [$recent, $line];
    return ($recent, $line);
}

sub parse_quote {
    my ($file, $line) = @_;
    my ($epoch, $price);
    my $provider = $file->parent->parent->basename;
    if ($provider ne 'combined') {
        ($epoch, undef, undef, undef, $price) = split ',', $line;
    } elsif ($line =~ /^(\d{2}:\d{2}:\d{2}) (\d{2}:\d{2}) (\d+\.?\d*) (\d+\.?\d*) (\d+\.?\d*).*\n$/) {
        my $time = $1;
        $price = $5;
        my $date = ($file->basename =~ s/((\d\d?-\w{3}-\d\d)\.fullfeed)?$/$2/r);
        # in case of crash outer try/catch will handle that
        $epoch = Date::Utility->new($date . ' ' . $time)->epoch;
    }
    return ($price, $epoch);
}

sub get_quote {
    my $dir = shift;
    my ($file, $line) = last_quote($dir);
    return parse_quote($file, $line);
}

PrintContentType();
BrokerPresentation('REALTIME QUOTES');
my $broker = request()->broker_code;
BOM::Backoffice::Auth0::can_access(['Quants']);

my @all_markets = Finance::Asset::Market::Registry->instance->all_market_names;
push @all_markets, 'futures';    # this is added to check for futures feed
my $feedloc = BOM::Platform::Runtime->instance->app_config->system->directory->feed;
my $dbloc   = BOM::Platform::Runtime->instance->app_config->system->directory->db;

my $now          = Date::Utility->new;
my @providerlist = qw(idata random telekurs sd bloomberg olsen synthetic combined panda);

Bar("Compare providers");

#colors help
print "<UL>COLORS USED:<LI><font color=FF8888>Over 180 seconds</font>";
print "<LI><font color=F0F0F0>Shadow tick file</font>";
print "<LI><font color=F09999>Shadow tick file over 180 seconds</font>";
print "<LI><font color=FF0000>More than 0.2\% away from combined quote (0.4\% for stocks)</font>";
print "</UL>";

my $ul_db = create_underlying_db();

my @instrumentlist = sort $ul_db->get_symbols_for(
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

    my $underlying = create_underlying($i);

    next unless $all or $underlying->calendar->is_open;

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
        my ($price, $timestamp, $spot);

        # Might die for a couple of reasons: file not exist, or error in parsing last line (partly written).
        # All this errors are non fatal, and will show just empty cell in backoffice; refresh in browser can fix
        # situation.
        try {
            ($price, $timestamp) = get_quote(path('/feed', $p, $underlying->symbol));
            # This is similar to underlying->spot, i.e. we always get the last value from combined file for comparison
            # but if the current provider is already 'combined' we just copy existing value
            ($spot) = ($p ne 'combined') ? get_quote(path('/feed', 'combined', $underlying->symbol)) : ($price);
        };

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
        print join ", ", @{$underlying->providers};
    }
    print "</td>";
    print "</tr>";
}

print "</table><P>";

code_exit_BO();
