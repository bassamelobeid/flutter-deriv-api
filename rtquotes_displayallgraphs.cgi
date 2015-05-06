#!/usr/bin/perl
package main;

use strict;
use f_brokerincludeall;
use BOM::Market::UnderlyingDB;
use BOM::Utility::GNUPlot;
use BOM::Utility::Hash;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Platform::Sysinit ();
use subs::subs_graphs;

BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("Plot Graph");
BOM::Platform::Auth0::can_access(['Quants']);

my $market = request()->param('market');

my $daily           = request()->param('daily');
my $norm_from_start = request()->param('norm_from_start');
my $overlay         = request()->param('overlay');
my $source          = request()->param('source');
my $all_provider    = request()->param('all_provider');
my $count           = request()->param('count') || 1;
my $yday            = request()->param('yday');
my $merge           = request()->param('merge');
my $upper           = request()->param('upper') || '';
my $lower           = request()->param('lower') || '';
my $time_upper      = request()->param('time_upper') || '';
my $time_lower      = request()->param('time_lower') || '';
my $use_y2          = request()->param('use_y2') || 0;
my @overlay         = split /\s+/, $overlay;
my @source          = split /\s+/, $source;
my @candle_c        = ();
my @candle_h        = ();
my @candle_l        = ();
my @candle_o        = ();

my $msg = '<br/>Number of lines in each file:<br/>';

# construct output file name
my $hashcat;
foreach my $hashkey (keys %{request()->params}) {
    $hashcat .= "$hashkey=" . request()->param($hashkey);
}
$hashcat = BOM::Utility::Hash::md5($hashcat);
$hashcat .= int(rand 100);
my $fileextention       = "gif";
my $graph_outputfile    = BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif . "/$hashcat.$fileextention";
my $graph_outputfile_ht = request()->url_for("temp/$hashcat.$fileextention");

my $now           = Date::Utility->new;
my $currenthour   = $now->hour;
my $currentminute = $now->minute;
my $today         = $now->date_ddmmmyy;
Bar("Plot Graph (Input Parameters) $today   $currenthour:$currentminute GMT");

print "<Body>";

my $norm_checked         = $norm_from_start ? 'checked' : '';
my $all_provider_checked = $all_provider    ? 'checked' : '';
my $merge_checked        = $merge           ? 'checked' : '';
my $use_y2_checked       = $use_y2          ? 'checked' : '';

print
    '<span style="align=center"><TABLE BORDER=1 CELLPADDING=1 CELLSPACING=0><TR><TD>MARKET</TD><TD><b>PROVIDER</TD><TD><b>BACKUP</TD><TD><b>2NDBACKUP</TD><TD><b>3RDBACKUP</TD></TR>';
foreach my $underlying_symbol ('frxUSDJPY', 'FTSE', 'UKBARC', 'USINTC') {
    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my $providers = join "</TD><TD>", @{$underlying->market->providers};
    print '<TR><TD><b>' . $underlying->market->name . '</TD><TD>' . $providers . "</TD></TR>";
}
print '</span>';

# Input Parameters
print qq~
	<form action="~ . request()->url_for('backoffice/rtquotes_displayallgraphs.cgi') . qq~">
	<TABLE border=0 cellpadding=1>
		<TR>
			<TD>&nbsp;</TD>
			<TD>&nbsp;</TD>
		</TR>
		<TR>
			<TD colspan=2><span style='font-size: 12pt'>Market Chart</span></TD>
		</TR>
		<TR>
			<TD align=right>Market (example: forex | indices | stocks | futures) :</TD>
			<TD><input type=text name="market" size=60 value="$market"/></TD>
		</TR>
		<TR>
			<TD>&nbsp;</TD>
			<TD>&nbsp;</TD>
		</TR>
		<TR>
			<TD colspan=2><span style='font-size: 12pt'>Daily Chart</span></TD>
		</TR>
		<TR>
			<TD align=right>Market (only for daily chart) :</TD>
			<TD><input type=text name="daily" size=60 value="$daily"/></TD>
		</TR>
		<TR>
			<TD>&nbsp;</TD>
			<TD>&nbsp;</TD>
		</TR>
		<TR>
			<TD colspan=2><span style='font-size: 12pt'>Intra-Day Chart</span></TD>
		</TR>
		<TR>
			<TD align=right>Normalize graph values from Start :</TD>
			<TD><input type=radio name="norm_from_start" value='1' $norm_checked>Yes <input type=radio name="norm_from_start" value="0">No<br/></TD>
		</TR>
		<TR>
			<TD align=right>Market (example: frxUSDJPY frxGBPJPY frxXAUUSD) :</TD>
			<TD><input type=text name="overlay" size=120 value="$overlay"/></TD>
		</TR>
		<TR>
			<TD align=right>Provider (example: telekurs gtis combined) :</TD>
			<TD><input type=text name="source" size=120 value="$source"/></TD>
		</TR>
		<TR>
			<TD align=right>Use all providers for each market :</TD>
			<TD><input type=radio name="all_provider" value='1' $all_provider_checked>Yes <input type=radio name="all_provider" value="0">No<br/></TD>
		</TR>
		<TR>
			<TD align=right>Start from how many days ago ?</TD>
			<TD><input type=text name="yday" size=15 value="$yday"/></TD>
		</TR>
		<TR>
			<TD align=right>Draw for how many days backward ?</TD>
			<TD>
				<input type=text name="count" size=15 value="$count"/>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
				<input type=radio name="merge" value='1' $merge_checked>Merge Graph <input type=radio name="merge" value="0">Seperate Graph<br/>
			</TD>
		</TR>
		<TR>
			<TD align=right>Upper and Lower limit :</TD>
			<TD>From (lower limit) <input type=text name="lower" size=15 value="$lower"/> To (upper limit) <input type=text name="upper" size=15 value="$upper"/></TD>
		</TR>
		<TR>
			<TD align=right>Time limits (hh:mm:ss) :</TD>
			<TD>From (lower limit) <input type=text name="time_lower" size=15 value="$time_lower"/> To (upper limit) <input type=text name="time_upper" size=15 value="$time_upper"/></TD>
		</TR>
		<TR>
			<TD align=right>Use Secondary Y axis (Applicable to first underlying only) :</TD>
			<TD><input type=radio name="use_y2" value='1' $use_y2_checked>Yes <input type=radio name="use_y2" value="0">No<br/></TD>
		</TR>
		<TR>
			<TD>&nbsp;</TD>
			<TD><input type="submit" value="Draw Graph"/></TD>
		</TR>
	</TABLE>
	</form>
~;

my $override_findfullfeed;
# DAILY CHART
if ($daily) {
    Bar("Daily Graph for $daily");

    #link to intraday charts
    print "Other Intraday Charts : <a href=\""
        . request()->url_for(
        'backoffice/rtquotes_displayallgraphs.cgi',
        {
            overlay => $daily,
            yday    => 0
        }) . "\">Intraday</a>";
    print "&nbsp; <a href=\""
        . request()->url_for(
        'backoffice/rtquotes_displayallgraphs.cgi',
        {
            overlay => $daily,
            yday    => 0,
            count   => 10
        }) . "\">10 last days</a>";
    print "&nbsp; <a href=\""
        . request()->url_for(
        'backoffice/rtquotes_displayallgraphs.cgi',
        {
            overlay => $daily,
            yday    => 0,
            count   => 25
        }) . "\">25 last days</a>";
    #link to edit daily OHLC file

    print "<center>&nbsp;<br>";

    my ($graph_x, $graph_y) = doDailyPlot({
        underlying_symbol => $daily,
        candle_c          => \@candle_c,
        candle_h          => \@candle_h,
        candle_l          => \@candle_l,
        candle_o          => \@candle_o
    });
    if (not $graph_x and not $graph_y) {
        print 'No Data available';
    }

    # 1    : 2 : 3  : 4 : 5
    # Date Open High Low Close
    my $daily_data;
    for (my $n = 0; $n < scalar @{$graph_x}; $n++) {
        $daily_data .= $graph_x->[$n] . ' ' . $candle_o[$n] . ' ' . $candle_h[$n] . ' ' . $candle_l[$n] . ' ' . $candle_c[$n] . "\n";
    }

    my $graphs_gnuplot = BOM::Utility::GNUPlot->new({
        'top_title'        => "Daily Charting - $daily",
        'background_color' => 'FFFFFF',
        'output_type'      => 'gif',
        'graph_grid'       => 'yes',
        'xdata_type'       => 'time',
        'x_label'          => "Date (MM:dd)",
        'y_label'          => '',
        'x_format'         => '%m/%y',
        'y_format'         => '%.4f',
        'time_format'      => '%d-%m-%y',
        'y_range'          => "$lower:$upper",
        'legend_border'    => 'box',
        'legend_position'  => 'out horiz bot right',
        'graph_size'       => '600,400',
        'output_file'      => $graph_outputfile,
    });

    $graphs_gnuplot->set_data_properties({
        'using'      => '1:2:3:4:5',
        'title'      => $daily,
        'graph_type' => 'financebars',
        'line_style' => 'lw 2 pt 1 ps 1 lc rgb "#026bd2"',
        'fill_style' => 'solid 0.2 noborder',
        'data'       => $daily_data,
    });

    my $filename = $graphs_gnuplot->plot();

    print "<img id=\"GnuPlotChart\" src=\"$graph_outputfile_ht\" border=\"0\" width=\"600\" height=\"400\" />";
    print qq~<textarea rows="25" cols="60">$daily_data</textarea>~;
}

# OVERLAY TWO OR MORE MARKETS (INTRADAY) - show intraday-graph separately
elsif (scalar @overlay and not $merge) {
    Bar("Intraday Graph for $overlay");

    my $now = Date::Utility->new;
    for (my $i = 0; $i < $count; $i++) {
        $graph_outputfile =~ s/.gif/$i.gif/;
        $graph_outputfile_ht =~ s/.gif/$i.gif/;
        my $which = ($yday) ? $yday + $i : $i;
        my $daytochart = Date::Utility->new($now->epoch - 86400 * $which)->date_ddmmmyy;

        my $graphs_gnuplot = BOM::Utility::GNUPlot->new({
            'top_title'        => "Intraday Chart - $overlay on $daytochart",
            'background_color' => 'FFFFFF',
            'output_type'      => 'gif',
            'graph_grid'       => 'yes',
            'xdata_type'       => 'time',                                       # time, string
            'x_label'          => '',
            'y_label'          => '',
            'x_format'         => '%H:%M',
            'y_format'         => '%.4f',
            'time_format'      => '%H:%M:%S',
            'y_range'          => "$lower:$upper",
            'legend_border'    => 'box',
            'legend_position'  => 'out horiz bot right',
            'graph_size'       => '990,600',
            'output_file'      => $graph_outputfile,
            'use_y2'           => $use_y2,
        });

        my $y2 = $use_y2;
        for (my $j = 0; $j < scalar @overlay; $j++) {
            my $instrument = $overlay[$j];
            my $provider = $source[$j] || 'combined';
            next if (not $instrument);
            my $underlying = BOM::Market::Underlying->new($instrument);

            my @providerlist;
            if ($all_provider) {
                @providerlist = qw(gtis idata random telekurs sd tenfore bloomberg olsen test combined);
            } else {
                push @providerlist, $provider;
            }

            foreach my $p (@providerlist) {
                if ($p eq 'combined') {
                    $override_findfullfeed = '';
                } else {
                    $override_findfullfeed = $p;
                }

                my $fffile = $underlying->fullfeed_file($daytochart, $override_findfullfeed);

                if (-e $fffile) {
                    $msg .= `wc -l $fffile` . '<br>';

                    my ($graph_x, $graph_y) = doPlot({
                        underlying_symbol     => $instrument,
                        candle_c              => \@candle_c,
                        candle_h              => \@candle_h,
                        candle_l              => \@candle_l,
                        candle_o              => \@candle_o,
                        override_findfullfeed => $override_findfullfeed,
                        daytochart            => $daytochart,
                        tick_by_tick          => 1
                    });

                    if (not $graph_x and not $graph_y) {
                        print "<span style='color:#FF0000;'>No data for $instrument [$provider] on $daytochart</span><br/>";
                        next;
                    }

                    my $data;
                    my $first = 0;

                    # 1   : 2
                    # Date Close
                    for (my $n = 0; $n < scalar @{$graph_x}; $n++) {
                        my $y;
                        if ($first == 0) {
                            $first = $graph_y->[$n];
                            if ($norm_from_start and $first == 0) {
                                next;
                            }

                            $y = $norm_from_start ? 100 : $first;
                        } else {
                            $y = $norm_from_start ? 100 * $graph_y->[$n] / $first : $graph_y->[$n];
                        }
                        # Filter by spot barriers
                        next if (($upper ne '' and $y > $upper) or ($lower ne '' and $y < $lower));

                        # Filter by time barriers
                        my $graphx_date = Date::Utility->new($daytochart . ' ' . $graph_x->[$n]);
                        if ($time_upper) {
                            my $upper_date = Date::Utility->new($daytochart . ' ' . $time_upper . 'GMT');
                            next if $graphx_date->epoch > $upper_date->epoch;
                        }
                        if ($time_lower) {
                            my $lower_date = Date::Utility->new($daytochart . ' ' . $time_lower . 'GMT');
                            next if $graphx_date->epoch < $lower_date->epoch;
                        }

                        $data .= $graph_x->[$n] . ' ' . $y . "\n";
                    }

                    if ($data) {
                        $graphs_gnuplot->set_data_properties({
                            'using' => '1:2',
                            'title' => "$instrument from [$p] on $daytochart",
                            #Assuming we upload excel vols less than 5 times a day. 'linespoints' are used for vols feed while 'lines' are used for ticks fullfeed file.
                            'graph_type' => (scalar @{$graph_x} < 5) ? 'linespoints' : 'lines',
                            'line_style' => '',
                            'fill_style' => '',
                            'data'       => $data,
                            'use_y2' => $y2,    # using secondary Y axis
                        });

                        $y2 = 0;                    # only use secondary Y axis for first time
                    } else {
                        print "<span style='color:#FF0000;'>No valid data for $instrument [$p] on $daytochart</span><br/>";
                    }
                } else {
                    print "<span style='color:#FF0000;'>Can't find fullfeed file for $instrument [$p] on $daytochart</span><br/>";
                }
            }
        }

        if (not $graphs_gnuplot->{'image_properties'} or not $graphs_gnuplot->{'data_properties'}) {
            next;
        }

        my $filename = $graphs_gnuplot->plot();
        print "<br/><br/><img id=\"GnuPlotChart\" src=\"$graph_outputfile_ht\" border=\"0\" width=\"990\" height=\"600\" /><br/>";
    }
}
# OVERLAY TWO OR MORE MARKETS (INTRADAY) - merge intraday-graph into single graph
elsif (scalar @overlay and $merge) {
    Bar("Intraday Graph (Merge) for $overlay");

    my $graphs_gnuplot = BOM::Utility::GNUPlot->new({
        'top_title'        => "Merge Intraday Chart - $overlay",
        'background_color' => 'FFFFFF',
        'output_type'      => 'gif',
        'graph_grid'       => 'yes',
        'xdata_type'       => 'time',
        'x_label'          => '',
        'y_label'          => '',
        'x_format'         => '%d/%m %H:%M',
        'y_format'         => '%.4f',
        'time_format'      => '%d-%m-%y_%H:%M:%S',
        'y_range'          => "$lower:$upper",
        'legend_border'    => 'box',
        'legend_position'  => 'out horiz bot right',
        'graph_size'       => '990,600',
        'output_file'      => $graph_outputfile,
    });

    for (my $i = 0; $i < scalar @overlay; $i++) {
        my $market = $overlay[$i];
        my $provider = $source[$i] || 'combined';

        next if (not $market);
        my $underlying = BOM::Market::Underlying->new($market);

        my @providerlist;
        if ($all_provider) {
            # put combined last so we can see it on top
            @providerlist = qw(gtis idata random telekurs sd tenfore bloomberg olsen test combined);
        } else {
            push @providerlist, $provider;
        }

        foreach my $p (@providerlist) {
            my $data;
            my $first;

            for (my $j = $count - 1; $j >= 0; $j--) {
                my $which      = ($yday) ? $yday + $j : $j;
                my $chart_date = Date::Utility->new($now->epoch - 86400 * $which);
                my $daytochart = $chart_date->date_ddmmmyy;

                my $ddmmyy =
                    sprintf('%02d', $chart_date->day_of_month) . '-' . sprintf('%02d', $chart_date->month) . '-' . $chart_date->year_in_two_digit;

                $override_findfullfeed = ($p eq 'combined') ? '' : $p;

                my $fffile = $underlying->fullfeed_file($daytochart, $override_findfullfeed);

                if (not -e $fffile) {
                    print '<span style="color:red;">Can\'t find fullfeed file for instrument['
                        . $market . '] ['
                        . $p
                        . '] on ['
                        . $daytochart
                        . ']</span><br/>';
                    next;
                }

                $msg .= `wc -l $fffile` . '<br>';

                my ($graph_x, $graph_y) = doPlot({
                    underlying_symbol     => $market,
                    candle_c              => \@candle_c,
                    candle_h              => \@candle_h,
                    candle_l              => \@candle_l,
                    candle_o              => \@candle_o,
                    override_findfullfeed => $override_findfullfeed,
                    daytochart            => $daytochart,
                });
                if (not $graph_x and not $graph_y) {
                    print "<span style='color:#FF0000;'>No data for $market [$provider] on $daytochart</span><br/>";
                    next;
                }

                my $num_of_row = scalar @{$graph_x};

                if (not $first) {
                    $first = $graph_y->[0];
                    if ($num_of_row) {
                        my $d = $ddmmyy . '_' . $graph_x->[0];
                        my $y = $norm_from_start ? 100 : $first;

                        $data .= $d . ' ' . $y . "\n";
                    }
                }

                # 1   : 2
                # Date Close
                my $i;
                if ($market =~ /^V_/) {
                    $i = 0;    #start from the first element for volatility feed, as typicaly we have only one volatility feed in a day
                } else {
                    $i          = 1;
                    $num_of_row = $num_of_row - 1;
                }

                for (my $n = $i; $n < $num_of_row; $n++) {
                    my $d = $ddmmyy . '_' . $graph_x->[$n];
                    my $y = $norm_from_start ? 100 * $graph_y->[$n] / $first : $graph_y->[$n];

                    next if (($upper ne '' and $y > $upper) or ($lower ne '' and $y < $lower));
                    $data .= $d . ' ' . $y . "\n";
                }
            }

            $graphs_gnuplot->set_data_properties({
                'using'      => '1:2',
                'title'      => "$market from [$p]",
                'graph_type' => 'lines',
                'line_style' => '',
                'fill_style' => '',
                'data'       => $data,
            });
        }
    }

    if (not $graphs_gnuplot->{'image_properties'} or not $graphs_gnuplot->{'data_properties'}) {
        print "<span style='color:#FF0000;'>No data to draw merge-intraday chart</span><br/>";
    }

    my $filename = $graphs_gnuplot->plot();
    print "<br/><br/><img id=\"GnuPlotChart\" src=\"$graph_outputfile_ht\" border=\"0\" width=\"990\" height=\"600\" /></br>";
}
# GRAPH ALL MARKETS
else {
    Bar("Market Chart for $market");

    print "<center>&nbsp;<br>";

    my $yesterday = Date::Utility->new($now->epoch - 86400)->date_ddmmmyy;

    foreach my $forexitem (
        BOM::Market::UnderlyingDB->instance->get_symbols_for(
            market       => $market,
            contract_category => 'ANY',
        ))
    {
        my $underlying = BOM::Market::Underlying->new($forexitem);
        print "<table cellpadding=0 cellspacing=0 border=1 width=100%><tr><td><font size=1>";
        my $daytochart   = $yesterday;
        my $graph_xtitle = "$forexitem $daytochart (YESTERDAY)";

        my $graph_title   = $underlying->display_name;
        my $graph_formatx = '%H:%M';
        my $graph_formaty = '%.4f';
        my $graph_sizex   = 340, my $graph_sizey = 300, my $graph_timeformat = '%H:%M:%S';

        my $graph_outputfile = graph_setup({
            graph_formatx    => $graph_formatx,
            graph_formaty    => $graph_formaty,
            graph_sizex      => $graph_sizex,
            graph_sizey      => $graph_sizey,
            graph_timeformat => $graph_timeformat,
            graph_title      => $graph_title,
            graph_xtitle     => $graph_xtitle,
        });

        Plot({
            market      => $forexitem,
            candle_c    => \@candle_c,
            candle_h    => \@candle_h,
            candle_l    => \@candle_l,
            candle_o    => \@candle_o,
            daytochart  => $daytochart,
            graph_title => $graph_title,
        });
        print graph_draw({
            graph_sizex      => $graph_sizex,
            graph_sizey      => $graph_sizey,
            graph_outputfile => $graph_outputfile,
        });

        print "</td><td><font size=1>";

        $daytochart   = $today;
        $graph_xtitle = "$forexitem $daytochart (TODAY)";

        $graph_outputfile = graph_setup({
            graph_formatx    => $graph_formatx,
            graph_formaty    => $graph_formaty,
            graph_sizex      => $graph_sizex,
            graph_sizey      => $graph_sizey,
            graph_timeformat => $graph_timeformat,
            graph_title      => $graph_title,
            graph_xtitle     => $graph_xtitle,
        });

        Plot({
            market      => $forexitem,
            candle_c    => \@candle_c,
            candle_h    => \@candle_h,
            candle_l    => \@candle_l,
            candle_o    => \@candle_o,
            daytochart  => $daytochart,
            graph_title => $graph_title,
        });
        print graph_draw({
            graph_sizex      => $graph_sizex,
            graph_sizey      => $graph_sizey,
            graph_outputfile => $graph_outputfile,
        });

        print "</td><td><font size=2>";

        # get ohlc daily up to 7 days back
        my $ohlcs = $underlying->ohlc_between_start_end({
            start_time         => $now->epoch - 86400 * 7,
            end_time           => $now->epoch,
            aggregation_period => 86400,
        });

        if (scalar @{$ohlcs} > 0) {
            print "<b>$forexitem</b><br/>";
            foreach my $ohlc (reverse @{$ohlcs}) {
                print join(' ', Date::Utility->new($ohlc->epoch)->date_ddmmmyy, $ohlc->open, $ohlc->high, $ohlc->low, $ohlc->close) . '<br/>';
            }
        } else {
            print "<font color=red><b>Can't get OHLC daily data";
        }

        print "</td></tr></table><br>";
    }
}

if (scalar @overlay) {
    print "$msg";
}

code_exit_BO();

