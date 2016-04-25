use strict 'vars';
use open qw[ :encoding(UTF-8) ];
use POSIX;
use Path::Tiny;
use BOM::Backoffice::GNUPlot;
use Date::Utility;
use BOM::Platform::Sysinit ();
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request);
use BOM::Market::Data::DatabaseAPI;
use BOM::Market::Underlying;
use BOM::View::Charting;

use String::UTF8::MD5;

my ($firstplot, $ip);

sub graph_setup {
    my $args             = shift;
    my $graph_formatx    = $args->{graph_formatx};
    my $graph_formaty    = $args->{graph_formaty};
    my $graph_sizex      = $args->{graph_sizex};
    my $graph_sizey      = $args->{graph_sizey};
    my $graph_timeformat = $args->{graph_timeformat};
    my $graph_title      = $args->{graph_title};
    my $graph_xtitle     = $args->{graph_xtitle};

    # error checks
    $ip = request()->client_ip;
    $ip =~ s/\./9/g;
    if ($ip =~ /(\d+)/) {
        $ip = $1 - 448445;
    }

    my $gif_dir = BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif;
    if (not $gif_dir) {
        print "[graph_setup] Error - system.directory.tmp_gif is undefined ";
        BOM::Platform::Sysinit::code_exit();
    }
    if (not -d $gif_dir) {
        Path::Tiny::path($gif_dir)->mkpath;
        if (not -d $gif_dir) {
            print "[graph_setup] Error - $gif_dir could not be created";
            BOM::Platform::Sysinit::code_exit();
        }
    }

    # make file name - according to %INPUT hash
    my $hashcat = $graph_formaty . $graph_formatx . $graph_timeformat . 'yes' . $graph_sizex . $graph_sizey . $graph_xtitle;
    foreach my $hashkey (keys %{request()->params}) {
        $hashcat .= "$hashkey=" . request()->param($hashkey);
    }
    $hashcat .= request()->loginid;    #to make it unique - in case we are plotting client trade points
    $hashcat = String::UTF8::MD5::md5($hashcat);
    $hashcat .= int(rand 100);

    my $graph_outputfile    = "$gif_dir/$hashcat.gif";
    my $graph_outputfile_ht = request()->url_for("temp/$hashcat.gif");
    if (-e $graph_outputfile) {
        my $timetodead = 0.5;          #minutes
        if ((-M $graph_outputfile) < $timetodead / 24 / 60) {
            return;
        }
    }

    # default graph settings
    local $\ = "";
    my $graph_background_and_table = 'ffffff';
    my $graph_link_and_line        = '000080';

    #GNU filehandle needs to be global - not sure if this makes mod_perl problems because of SIG_PIPE handling
    my $gnu_plot = BOM::Backoffice::GNUPlot::gnuplot_command();
    open(GNU, "| $gnu_plot") or die "[$0] execute of '$gnu_plot' failed $!";
    print GNU "set key box\n";
    print GNU "set key out horiz\n";
    print GNU "set key bot right\n";
    print GNU "set key width 0.5\n";
    print GNU "set key height 0.5\n";
    print GNU "set title \"$graph_title\" offset 0,-0.5\n";
    print GNU "set xlabel \"$graph_xtitle\" 0,0\n";
    print GNU "set grid\n";

    #   bg     border   axes   plotting colors....
    print GNU
        "set terminal gif small size $graph_sizex,$graph_sizey x$graph_background_and_table x000000 x$graph_link_and_line x$graph_link_and_line x39009C x39009C xD60008 xCE9A9C x008631 x0000ff xdda0dd\n"
        ;    #transparent

    print GNU "set output \"$graph_outputfile\"\n";
    print GNU "set timefmt \"$graph_timeformat\"\n";
    print GNU "set format x \"$graph_formatx\"\n";
    print GNU "set xdata time\n";
    print GNU "set nomxtics\n";

    print GNU "set format y \"$graph_formaty\"\n";
    print GNU "set pointsize 1\n";
    print GNU "set style line 2 lw 1 pt 1 ps 1\n";
    print GNU "set style line 3 lw 1 pt 1 ps 1 lc rgb \"#f6be4a\"\n";
    print GNU "set style line 4 lw 1 pt 1 ps 2\n";
    print GNU "set style line 5 lw 1 pt 1 ps 1\n";
    print GNU "set style line 6 lw 1 pt 1 ps 1\n";
    print GNU "set style line 7 lw 1 pt 1 ps 1\n";
    print GNU "set style line 8 lw 1 pt 1 ps 1 lc rgb \"#00B900\"\n";
    print GNU "set style line 9 lw 1 pt 1 ps 1 lc rgb \"F00000\"\n";
    print GNU "set style line 10 lw 1 pt 1 ps 1 lc rgb \"#f6be4a\"\n";
    print GNU "set style line 11 lw 2 pt 1 ps 1 lc rgb \"#00B900\"\n";
    print GNU "set style line 12 lw 2 pt 1 ps 1 lc rgb \"F00000\"\n";
    print GNU "set style line 13 lw 2 pt 1 ps 1 lc rgb \"#3366FF\"\n";
    print GNU "set style fill solid 0.25 border\n";

    $firstplot = 0;

    return ($graph_outputfile, $graph_outputfile_ht);
}

sub graph_plot {
    my $arg_ref     = shift;
    my $candle_c    = $arg_ref->{'candle_c'};
    my $candle_h    = $arg_ref->{'candle_h'};
    my $candle_l    = $arg_ref->{'candle_l'};
    my $candle_o    = $arg_ref->{'candle_o'};
    my $graph_title = $arg_ref->{'graph_title'};
    my @graph_x     = @{$arg_ref->{'graph_x'}};
    my @graph_y     = @{$arg_ref->{'graph_y'}};

    my $thecomma;
    if ($firstplot == 0) {
        $thecomma = "plot";
    } else {
        $thecomma = ",";
    }

    my $graph_datafile = BOM::Platform::Runtime->instance->app_config->system->directory->tmp . "/$ip-$firstplot.dat";

    my @temp_array_candle_c = @{$candle_c};
    my @temp_array_candle_h = @{$candle_h};
    my @temp_array_candle_l = @{$candle_l};
    my @temp_array_candle_o = @{$candle_o};
    my $using;
    local $\ = "";
    local *DATAF;
    unlink $graph_datafile;    #fix tmpfs bug
    if (open(DATAF, ">$graph_datafile")) {
        flock(DATAF, 2);
        for (my $n = 0; $n < scalar @graph_x; $n++) {
            if ($graph_x[$n]) {
                print DATAF $graph_x[$n] . ' ' . $graph_y[$n] . "\n";
                $using = "";
            }
        }

        close(DATAF);
    } else {
        warn("Can't write to $graph_datafile $@ $!");
        return;
    }

    my $print_ref = $graph_title;
    print GNU "$thecomma \"$graph_datafile\" using 1:2$using t \"$print_ref\" with lines";

    $firstplot++;
}

sub graph_draw {
    my $args                = shift;
    my $graph_sizex         = $args->{graph_sizex};
    my $graph_sizey         = $args->{graph_sizey};
    my $graph_outputfile    = $args->{graph_outputfile};
    my $graph_outputfile_ht = $args->{graph_outputfile_ht};

    local $\ = "";

    print GNU "\n";
    close GNU;

    if (not -s $graph_outputfile)    #not exists and has non-zero size
    {
        return;
    }

    return "<img id=\"GnuPlotChart\" src=\"$graph_outputfile_ht\" border=\"0\" width=\"$graph_sizex\" height=\"$graph_sizey\" />";
}

# intraday data: gets data from file or database (doPlot). If present it looks up contracts bought by clients to display in graph
sub Plot {
    my $arg_ref = shift;

    my $market      = $arg_ref->{'market'};
    my $candle_c    = $arg_ref->{'candle_c'};
    my $candle_h    = $arg_ref->{'candle_h'};
    my $candle_l    = $arg_ref->{'candle_l'};
    my $candle_o    = $arg_ref->{'candle_o'};
    my $daytochart  = $arg_ref->{'daytochart'};
    my $graph_title = $arg_ref->{'graph_title'};

    # gets the data
    my ($graph_x, $graph_y) = doPlot({
        underlying_symbol => $market,
        candle_c          => $candle_c,
        candle_h          => $candle_h,
        candle_l          => $candle_l,
        candle_o          => $candle_o,
        daytochart        => $daytochart,
    });

    if (not $graph_x and not $graph_y) {
        return;
    }

    graph_plot({
        candle_c    => $candle_c,
        candle_h    => $candle_h,
        candle_l    => $candle_l,
        candle_o    => $candle_o,
        graph_title => $graph_title,
        graph_x     => $graph_x,
        graph_y     => $graph_y,
    });
}

sub doPlot {
    my $arg_ref = shift;

    my $underlying_symbol     = $arg_ref->{'underlying_symbol'};
    my $candle_c              = $arg_ref->{'candle_c'};
    my $candle_h              = $arg_ref->{'candle_h'};
    my $candle_l              = $arg_ref->{'candle_l'};
    my $candle_o              = $arg_ref->{'candle_o'};
    my $override_findfullfeed = $arg_ref->{'override_findfullfeed'};
    my $tick_by_tick          = $arg_ref->{'tick_by_tick'};
    my $daytochart            = $arg_ref->{'daytochart'};

    my (@graph_x, @graph_y);
    my $firsty     = '';
    my $firstgtime = 0;

    if ($underlying_symbol =~ /^\^(.+)$/) {
        $underlying_symbol = $1;
    }

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);
    my $pip_size   = $underlying->pip_size;

    # get data from history server
    my $interval = 0;

    # set default value if null
    if (not $daytochart) {
        $daytochart = Date::Utility->new->date_ddmmmyy;
        $interval   = 600;
    }

    # When displaying all intraday data in a graph, use 1 min intervals.
    if (not $interval and not $tick_by_tick) {
        $interval = 60;
    }

    # we don't store provider specific ticks in OTN. So temporarily for provider specific feed, read from fullfeed files
    if (not $override_findfullfeed) {
        my $feed_hash_ref = BOM::View::Charting::getFeedsFromHistoryServer({
            stock     => $underlying_symbol,
            interval  => $interval,
            beginTime => Date::Utility->new($daytochart)->epoch,
            endTime   => Date::Utility->new($daytochart)->epoch + 86400,
            limit     => 86400,
        });

        if (not $feed_hash_ref) {
            return;
        }

        # Process the data.
        foreach my $dt (sort { $a <=> $b } keys %{$feed_hash_ref}) {
            my $price;
            my $open;
            my $high;
            my $low;
            my $close;
            my $ask;
            my $bid;
            my $gtime;
            my $quotetime;

            # tick data
            if (not $interval) {
                $price = $feed_hash_ref->{$dt}{'quote'};
                $ask   = $feed_hash_ref->{$dt}{'ask'};
                $bid   = $feed_hash_ref->{$dt}{'bid'};
            } else {
                $open  = $feed_hash_ref->{$dt}{'open'};
                $high  = $feed_hash_ref->{$dt}{'high'};
                $low   = $feed_hash_ref->{$dt}{'low'};
                $close = $feed_hash_ref->{$dt}{'close'};
                $price = $feed_hash_ref->{$dt}{'open'};
            }

            $price = $underlying->pipsized_value($price);

            # Determine the timestamp to show
            my $quote_date = Date::Utility->new({epoch => $dt});

            $gtime = $quote_date->time_hhmmss;

            $gtime =~ /^(\d*:\d*)/;
            $quotetime = $1;

            if ($interval > 0)    #we're cutting it by minute interval
            {
                push @{$candle_o}, $open;
                push @{$candle_h}, $high;
                push @{$candle_l}, $low;
                push @{$candle_c}, $close;

                if ($arg_ref->{'use_datetime_x_format'}) {
                    push @graph_x, $quote_date->date_yyyymmdd . $quote_date->time_hhmmss;
                } else {
                    push @graph_x, $gtime;
                }

                push @graph_y, $price;
            } else {
                push @graph_x, $gtime;
                push @graph_y, $price;
            }
        }
    } else {
        # For provider specific feed - still get from fullfeed files
        my $fffile = path($underlying->fullfeed_file($daytochart, $override_findfullfeed));
        return unless $fffile->exists;
        my @slurp = $fffile->lines({chomp => 1});
        return unless @slurp;

        my ($interval_high, $interval_low, $interval_open);
        my $last_epoch = 0;
        foreach my $l (@slurp) {
            my ($epoch, $bid, $ask, $last, $price, $src, $flags) = split /,/, $l;
            next unless $epoch or $epoch <= $last_epoch;
            next if $flags =~ /IGN|BADSRC/;
            $last_epoch = $epoch;

            if ($price) {
                my $gtime = POSIX::strftime("%H:%M:%S", gmtime $epoch);
                my $mm = int($epoch / 60);
                $mm %= 60;

                push @graph_x, $gtime;
                push @graph_y, $price;
            }
        }
    }
    return (\@graph_x, \@graph_y);
}

sub doDailyPlot {
    my $arg_ref           = shift;
    my $underlying_symbol = $arg_ref->{'underlying_symbol'};
    my $candle_c          = $arg_ref->{'candle_c'};
    my $candle_h          = $arg_ref->{'candle_h'};
    my $candle_l          = $arg_ref->{'candle_l'};
    my $candle_o          = $arg_ref->{'candle_o'};
    @{$candle_h} = ();
    @{$candle_l} = ();
    @{$candle_o} = ();
    my $previousline;

    my (@graph_x, @graph_y);
    my $firsty = "";

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);

    my $ohlcs = BOM::Market::Data::DatabaseAPI->new(underlying => $underlying_symbol)->ohlc_daily_until_now_for_charting({
        limit => 99999,
    });

    if (scalar @{$ohlcs} <= 0) {
        return;
    }

    foreach my $ohlc (@{$ohlcs}) {
        my $then = Date::Utility->new($ohlc->epoch);

        my $date = $then->date_ddmmyy;

        my $open  = $ohlc->open;
        my $high  = $ohlc->high;
        my $low   = $ohlc->low;
        my $price = $ohlc->close;

        my $priceline = join ' ', ($open, $high, $low, $price);

        # weekend - this seems like a pretty big assumption to make on this kind of data.
        # (does this really mean the weekend tho? what would happen on Randoms?)
        next if ($priceline eq $previousline);

        $previousline = $priceline;

        push @graph_x, $date;

        push @graph_y, $price;
        push @{$candle_o}, $open;
        push @{$candle_h}, $high;
        push @{$candle_l}, $low;
        push @{$candle_c}, $price;
    }

    return (\@graph_x, \@graph_y);
}

1;
