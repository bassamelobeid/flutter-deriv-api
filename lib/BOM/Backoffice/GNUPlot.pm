package BOM::Backoffice::GNUPlot;
use strict;
use warnings;
use Time::HiRes ('gettimeofday');
use BOM::Backoffice::Config qw/get_tmp_path_or_die/;
use Path::Tiny;
use open qw[ :encoding(UTF-8) ];

# constructor
sub new {
    my $class = shift;
    my $args  = shift;

    my $self = bless {}, $class;

    $self->initialise($args);

    return $self;
}

sub initialise {
    my $self = shift;
    my $args = shift;

    # Default values
    $self->{'top_title'}         = $args->{'top_title'}         || '';
    $self->{'background_color'}  = $args->{'background_color'}  || 'FFFFFF';
    $self->{'output_type'}       = $args->{'output_type'}       || 'png';
    $self->{'graph_border_opts'} = $args->{'graph_border_opts'} || '4095';
    $self->{'graph_grid'}        = $args->{'graph_grid'}        || 'yes';
    $self->{'xtics'}             = $args->{'xtics'}             || '';
    $self->{'ytics'}             = $args->{'ytics'}             || '';
    $self->{'xdata_type'}        = $args->{'xdata_type'}        || '';
    $self->{'point_size'}        = $args->{'point_size'}        || 1;
    $self->{'x_label'}           = $args->{'x_label'}           || '';
    $self->{'y_label'}           = $args->{'y_label'}           || '';
    $self->{'x_format'}          = $args->{'x_format'}          || '%d/%m';
    $self->{'y_format'}          = $args->{'y_format'}          || '';
    $self->{'time_format'}       = $args->{'time_format'}       || '%d-%m-%y';
    $self->{'x_range'}           = $args->{'x_range'}           || '';
    $self->{'y_range'}           = $args->{'y_range'}           || '';
    $self->{'legend_border'}     = $args->{'legend_border'}     || 'box';
    $self->{'legend_position'}   = $args->{'legend_position'}   || 'out horiz bot right';
    $self->{'graph_size'}        = $args->{'graph_size'}        || '660,330';
    $self->{'fill_style'}        = $args->{'fill_style'}        || 'solid 0.25 border';
    $self->{'extra'}             = $args->{'extra'}             || '';
    $self->{'output_file'}       = $args->{'output_file'}       || '';
    $self->{'start_time'}        = Time::HiRes::gettimeofday();
    $self->{'use_y2'}            = $args->{'use_y2'}            || '';                      # bool value: to use secondary Y axis or not?

    # GNUPLOT color format: xFF0000
    $self->{'background_color'} =~ s/^#//;

    # Others values
    $self->{'user_ip'} = $ENV{'REMOTE_ADDR'};
    $self->{'user_ip'} =~ s/\./9/g;
    if ($self->{'user_ip'} =~ /(\d+)/) { $self->{'user_ip'} = $1 - 448445; }

    # Default output file
    if (not $self->{'output_file'}) { $self->set_graph_tmpfile(); }

    return $self->set_image_properties();
}

# Check for valid graph type, return false if it's not in the @available_graph_types array.
sub is_valid_graph_type {
    my ($self, $graph_type) = @_;

    my @available_graph_types =
        ('lines', 'linespoints', 'points', 'impulses', 'steps', 'fsteps', 'boxes', 'financebars', 'dots', 'candlesticks', 'filledcurves');

    foreach my $gt (@available_graph_types) {
        if (defined $graph_type) {
            return 1 if $gt eq lc $graph_type;
        }
    }

    return;
}

# Set a unique hash value for the requested image file name to $self->{'output_file'}
sub set_graph_tmpfile {
    my ($self) = @_;

    my $hashcat = time . int(rand 100);

    $self->{'output_file'} = get_tmp_path_or_die() . '/chart_image_caches/' . $hashcat . '.' . $self->{'output_type'};
    return;
}

# Setup the stage for plotting the chart image
sub set_image_properties {
    my ($self) = @_;

    # Error Checks
    my ($graphx, $graphy) = split(',', $self->{'graph_size'});
    if ($graphx < 10              or $graphx > 5000)             { die "[$0] invalid graphx=$graphx"; }
    if ($graphy < 10              or $graphy > 5000)             { die "[$0] invalid graphy=$graphy"; }
    if ($self->{'point_size'} < 1 or $self->{'point_size'} > 40) { die "[$0] invalid pointsize=" . $self->{'point_size'}; }

    my @settings;
    {
        push @settings, 'set key ' . $self->{'legend_border'} if $self->{'legend_border'};

        if ($self->{'legend_position'}) {
            my $pos = 'set key ';
            while ($self->{'legend_position'} =~ s/(ins|out|horiz|vert)//) { $pos .= $1 . ' '; }
            push @settings, $pos;

            $pos = 'set key ';
            while ($self->{'legend_position'} =~ s/(left|right|top|bot)//) { $pos .= $1 . ' '; }
            push @settings, $pos;
        }

        push @settings, 'set title "' . $self->{'top_title'} . '" offset 0,-0.5' if $self->{'top_title'};
        push @settings, 'set xlabel "' . $self->{'x_label'} . '" offset 0,-1'    if $self->{'x_label'};
        push @settings, 'set ylabel "' . $self->{'y_label'} . '" offset 0,0'     if $self->{'y_label'};
        push @settings, 'set xrange [' . $self->{'x_range'} . ']'                if $self->{'x_range'};
        push @settings, 'set yrange [' . $self->{'y_range'} . ']'                if $self->{'y_range'};
        push @settings, 'set grid'                                               if $self->{'graph_grid'};
        push @settings, 'set style fill ' . $self->{'fill_style'}                if $self->{'fill_style'};

        if ($self->{'output_type'} eq 'gif') {
            # bg     border   axes   plotting colors....
            push @settings,
                  'set terminal gif small size '
                . $self->{'graph_size'}
                . ' xffffff x000000 x006563 xb70000 x008f00 x00008a xb0b000 xCE9A9C x008631 x0000ff xdda0dd';    #transparent
        } else {
            push @settings, 'set terminal png small size ' . $self->{'graph_size'} . ' x' . $self->{'background_color'};
            push @settings, 'set border ' . $self->{'graph_border_opts'};
            push @settings, 'set size 1, 1';
        }

        push @settings, 'set output "' . $self->{'output_file'} . '"';

        if ($self->{'xdata_type'} eq 'time') {
            push @settings, 'set timefmt "' . $self->{'time_format'} . '"';
            push @settings, 'set xdata time';
            push @settings, 'unset mxtics';
        }

        push @settings, 'set xtics ' . $self->{'xtics'} if $self->{'xtics'};
        push @settings, 'set ytics ' . $self->{'ytics'} if $self->{'ytics'};
        push @settings, 'set y2tics '                   if $self->{'use_y2'};    # y2 axis is hidden by default, so we need to explicitly set it
        push @settings, 'set format x "' . $self->{'x_format'} . '"' if $self->{'x_format'};
        push @settings, 'set format y "' . $self->{'y_format'} . '"' if $self->{'y_format'};
        push @settings, 'set pointsize ' . $self->{'pointsize'}      if $self->{'pointsize'};
    }

    $self->{'image_properties'} = join "\n", @settings;
    return;
}

# To prepare set of data to be plotted
sub set_data_properties {
    my ($self, $args) = @_;

    my $using          = $args->{'using'};
    my $title          = $args->{'title'} ? ' ' . $args->{'title'} : '';    # Extra space infront to prevent it touches the border
    my $graph_type     = $args->{'graph_type'};
    my $line_style     = $args->{'line_style'};
    my $fill_style     = $args->{'fill_style'};
    my $data           = $args->{'data'};
    my $region_to_plot = $args->{'region_to_plot'};
    my $use_y2         = $args->{'use_y2'};                                 # bool value: this data is plot against secondary Y axis or not?

    # Error checks
    $graph_type = $graph_type // "Undefined Value";
    $data       = $data       // "Undefined Value";

    if (not $self->is_valid_graph_type($graph_type)) { die "[$0] invalid graph_type='$graph_type'"; }

    # Lines do not need a fill style
    if ($args->{'graph_type'} eq 'lines') { $fill_style = ''; }

    if ($data ne 'same') {
        $self->{'plot_num'}++;
        $self->{'graph_datafile'} = get_tmp_path_or_die() . '/' . $self->{'user_ip'} . '-' . $self->{'plot_num'} . '.dat';

        $data =~ s/\n$//g;

        unlink $self->{'graph_datafile'};    #fix tmpfs bug
        path($self->{'graph_datafile'})->spew_raw($data);

        # [EXPERIMENTAL]
        # X-Axis string data are not supported on 4.2 yet,
        # we need to do it manually e.g. set xtics ('Dickens' 0, 'Hemingway' 1, 'Solzhenitsyn' 2)
        if ($self->{'xdata_type'} eq 'string') {
            if (not $self->{'set_xtics'}) {
                $self->{'set_xtics'} = 'set xtics (';

                my @xtics;
                my $i      = 0;
                my $xrange = 'set xrange [' . $i . ':';
                foreach my $xy (split "\n", $data) {
                    if ($xy =~ s/^(\w+)\s[\w-]+//) {
                        push @xtics, '\'' . $1 . '\'' . ' ' . $i;
                        $i++;
                    }
                }

                $self->{'set_xtics'} .= join(', ', @xtics) . ')';
                $self->{'image_properties'} .= "\n" . $self->{'set_xtics'};
                $self->{'image_properties'} .= "\n" . $xrange . $i . ']';
            }

            if ($using eq '1:2') { $using = '2'; }
        }
    }

    if ($line_style) {
        $self->{'line_style_id'}++;
        $self->{'image_properties'} .= "\n" . 'set style line ' . $self->{'line_style_id'} . ' ' . $line_style;
    }

    my @options;
    {
        push @options, '"' . $self->{'graph_datafile'} . '"';
        push @options, 'using ' . $using;
        push @options, 'axes x1y2' if $use_y2;
        push @options, 't "' . $title . '"';
        push @options, 'with ' . $graph_type;
        push @options, $region_to_plot if $region_to_plot;
        push @options, 'ls ' . $self->{'line_style_id'} if $line_style;
        push @options, 'fs ' . $fill_style if $fill_style;
    }

    my $data_properties = join ' ', @options;

    if (not $self->{'data_properties'}) { $self->{'data_properties'} = $data_properties; }
    else                                { $self->{'data_properties'} .= ', ' . $data_properties; }
    return;

}

# Run gnuplot command line
sub plot {
    my ($self) = @_;

    if (not $self->{'image_properties'} or not $self->{'data_properties'}) { die "[$0] Could not plot without image properties or data"; }

    my $gnu_plot = gnuplot_command();
    open my $gnu, '|-', $gnu_plot or die "[$0] execute of '$gnu_plot' failed $!";
    print $gnu $self->{'image_properties'} . "\n" . $self->{'extra'} . "\n" . 'plot ' . $self->{'data_properties'} . "\n";
    close $gnu;

    return $self->{'output_file'};
}

sub gnuplot_command {
    my $d = get_tmp_path_or_die();
    return "$d/gnuplot/gnuplot 1>/dev/null 2>> $d/gnuploterrors.log";
}

1;
