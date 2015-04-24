package BOM::MarketData::Display::VolatilitySurface;

use Moose;

use Date::Utility;
use BOM::Platform::Runtime;
use BOM::Platform::Context qw(request template);
use Format::Util::Numbers qw( roundnear );
use BOM::MarketData::VolSurface::Converter qw( get_1vol_butterfly );
use BOM::MarketData::Fetcher::VolSurface;
use BOM::Utility::GNUPlot;
use Try::Tiny;

=head1 surface

The surface object that you want to display

=cut

has surface => (
    is       => 'ro',
    isa      => 'BOM::MarketData::VolSurface',
    required => 1,
);

has _field_separator => (
    is      => 'ro',
    default => "\t",
);

has _output_format => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build__output_format {
    my $self = shift;

    my $print_precision = $self->surface->print_precision;
    return ($print_precision) ? '%.' . $print_precision . 'f' : undef;
}

=head1 rmg_table_format

Output the volatility surface in table format.

=cut

sub rmg_table_format {
    my ($self, $args) = @_;

    my $volsurface       = $self->surface;
    my $atm_spread_point = $volsurface->atm_spread_point;
    my $dates            = (defined $args->{historical_dates}) ? $args->{historical_dates} : [];
    my $tab_id           = (defined $args->{tab_id}) ? $args->{tab_id} : undef;
    my $greeks           = (defined $args->{greeks}) ? $args->{greeks} : undef;
    my $content_only     = (defined $args->{content_only}) ? $args->{content_only} : undef;

    my $dates_tt;
    foreach my $date (@{$dates}) {
        my $surface_date   = Date::Utility->new($date);
        my $new_volsurface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
            underlying => $volsurface->underlying,
            for_date   => $surface_date
        });
        my $calibration_error =
            ($new_volsurface->type eq 'moneyness' and $new_volsurface->parameterization and $new_volsurface->calibration_error)
            ? roundnear(0.01, $new_volsurface->calibration_error)
            : 'none';
        my $day          = $surface_date->day_as_string;
        my $date_display = '(' . $day . ') ' . $surface_date->db_timestamp;
        push @{$dates_tt},
            {
            value             => $date,
            display           => $date_display,
            calibration_error => $calibration_error,
            };
    }

    my @headers  = ('days');
    my $hour_age = sprintf('%.2f', (Date::Utility->new->epoch - $volsurface->recorded_date->epoch) / 3600);
    my $title    = $volsurface->recorded_date->datetime . ' (' . $hour_age . ' hours ago)';
    my $cut      = $volsurface->cutoff->code;

    my $forward_vols = $self->get_forward_vol();
    my @surface;
    my @days       = @{$volsurface->original_term_for_smile};
    my @tenors     = map { $volsurface->surface->{$_}->{tenor} || 'n/a' } @days;
    my $underlying = $volsurface->underlying;

    if ($volsurface->type eq 'moneyness') {
        push @headers, qw(tenor date forward_vol RR 2vBF 1vBF skew kurtosis);
        my @points = @{$volsurface->smile_points};
        push @headers, @points;
        @surface = $self->calculate_moneyness_vol_for_display;
    } elsif (
        scalar grep {
            $volsurface->type eq $_
        } (qw(flat phased)))
    {
        push @headers, qw(tenor date flat_vol flat_atm_spread);
        @surface =
            map { [$volsurface->flat_vol, $volsurface->flat_atm_spread] } @days;
    } elsif ($volsurface->type eq 'delta') {
        my @deltas = (sort { $a <=> $b } @{$volsurface->deltas});
        my @vol_spreads_points;

        foreach my $delta (@{$volsurface->spread_points}) {
            if ($delta =~ /^\d+/) {
                push @vol_spreads_points, $delta . 'D_spread' . '</th>';
            } else {
                push @vol_spreads_points, $delta;
            }
        }

        foreach (@deltas) {
            push @headers, $_;
        }

        @headers = ('days', 'tenor', 'date', @deltas, @vol_spreads_points, '1-day Forward Vol', 'RR', '2vBF', '1vBF', 'Skew', 'Kurtosis');

        for (my $i = 0; $i < scalar @days; $i++) {
            my $day    = $days[$i];
            my $smile  = $volsurface->get_smile($day);
            my $spread = $volsurface->get_smile_spread($day);

            if ($atm_spread_point ne 'atm_spread') {
                $spread = $spread->{'vol_spread'};
            }

            my @row;
            for (my $j = 0; $j < scalar @deltas; $j++) {
                my $delta = $deltas[$j];

                # display as %
                push @row, sprintf('%.3f', $smile->{$delta} * 100);

            }

            foreach (@{$volsurface->spread_points}) {
                my $spread_point = $_;

                # display as %
                push @row, sprintf('%.3f', $spread->{$spread_point} * 100);

            }

            # Forward Vol
            my $fv;
            if (grep { $day == $_ } @{$volsurface->original_term_for_smile}) {
                $fv = sprintf('%.3f', $forward_vols->{$day} * 100);
            }
            push @row, $fv;

            # rr, 2vBF
            my $rr_bf = $volsurface->get_rr_bf_for_smile($smile);

            # 1vBF
            my $tiy     = $day / 365;
            my $bf_1vol = get_1vol_butterfly({
                spot             => $underlying->spot,
                tiy              => $tiy,
                delta            => 0.25,
                call_vol         => $smile->{25},
                put_vol          => $smile->{75},
                atm_vol          => $smile->{50},
                bf_1vol          => 0,
                r                => $underlying->interest_rate_for($tiy),
                q                => $underlying->dividend_rate_for($tiy),
                premium_adjusted => $underlying->{market_convention}->{delta_premium_adjusted},
                bf_style         => '2_vol',
            });
            foreach ($rr_bf->{RR_25}, $rr_bf->{BF_25}, $bf_1vol) {
                push @row, sprintf('%.3f', ($_ * 100));
            }

            # skew, kurtosis
            my $skew = $self->get_skew_kurtosis($rr_bf);
            foreach ($skew->{skew}, $skew->{kurtosis}) {
                push @row, sprintf('%.3f', (($_) ? $_ : "0"));
            }
            push @surface, [@row];
        }
    }

    @days = map { ($_ =~ /\./) ? sprintf('%.5f', $_) : $_ } @days;

    my @dates = map {
        my $day  = $_;
        my $date = 'n/a';
        if (grep { $day eq $_ } @{$volsurface->original_term_for_smile}) {
            $date = Date::Utility->new($volsurface->recorded_date->epoch + $day * 86400)->date;
        }
        $date;
    } @days;

    my $table1_param = {
        title   => 'Call implied vols',
        headers => [@headers],
        days    => [@days],
        tenors  => [@tenors],
        dates   => [@dates],
        surface => [@surface],
        notes   => 'Notes: 1-day forward vol of day-365, is actually the forward vol for day-271 to day-365, etc',
    };

    my $ON_cut_date =
        $volsurface->cutoff->cutoff_date_for_effective_day(Date::Utility->new($volsurface->effective_date->epoch + $volsurface->_ON_day * 86400),
        $underlying);

    my $template_param = {
        historical_dates => $dates_tt,
        big_title        => $title,
        cut              => $volsurface->cutoff->code,
        ON_cut_datetime  => $ON_cut_date->datetime,
        underlying       => $underlying->symbol,
        tab_id           => $tab_id,
        table1           => $table1_param,
    };

    # Greeks
    if ($greeks) {
        @headers = ('days', 'tenor', 'date', 'Cost of vanna', 'Cost of volga', 'Cost of vega');
        @surface = ();
        for (my $i = 0; $i < scalar @days; $i++) {
            my $day = $days[$i];
            my @row = ($greeks->{$day}->{vanna}, $greeks->{$day}->{volga}, $greeks->{$day}->{vega});
            push @surface, [@row];
        }
        $template_param->{table2} = {
            title   => 'Cost of Greeks',
            headers => [@headers],
            days    => [@days],
            tenors  => [@tenors],
            dates   => [@dates],
            surface => [@surface],
        };
    }

    my $template_name = 'backoffice/price_debug/vol_form.html.tt';
    if ($content_only) {
        $template_name = 'backoffice/price_debug/vol_table.html.tt';
    }

    my $surface_html;
    template()->process($template_name, $template_param, \$surface_html)
        || die template()->error;

    return $surface_html;
}

sub get_forward_vol {
    my $self = shift;

    my $volsurface = $self->surface;
    my $atm_key = (grep { $volsurface->type =~ $_ } qw(delta flat phased)) ? 50 : 100;

    my @days = @{$volsurface->original_term_for_smile};

    my %implied_vols;
    foreach my $day (@days) {
        my $smile = $volsurface->get_smile($day);
        $implied_vols{$day} = $smile->{$atm_key};
    }

    my %weights;
    for (my $i = 1; $i <= $days[scalar(@days) - 1]; $i++) {
        my $date = Date::Utility->new({epoch => ($volsurface->recorded_date->epoch + $i * 86400)});
        $weights{$i} = $volsurface->underlying->weight_on($date);
    }

    my $forward_vols;
    my $prev_day = 0;
    foreach my $day (sort { $a <=> $b } keys %implied_vols) {

        # Iain Clark: page 72, formula 4.10
        my $variance_prev =
              ($implied_vols{$prev_day})
            ? ($implied_vols{$prev_day}**2 * $prev_day)
            : 0;
        my $total_variance_diff = $implied_vols{$day}**2 * $day - $variance_prev;
        my $sum_weight          = 0;
        for (my $i = $prev_day + 1; $i <= $day; $i++) {
            $sum_weight += $weights{$i};
        }
        my $fv = sqrt($total_variance_diff / $sum_weight);
        for (my $i = $prev_day + 1; $i <= $day; $i++) {
            $forward_vols->{$i} = $fv;
        }
        $prev_day = $day;
    }
    return $forward_vols;
}

sub get_skew_kurtosis {
    my ($self, $rr_bf) = @_;
    my ($skew, $kurtosis);
    if ($rr_bf->{RR_25} and $rr_bf->{BF_25} and $rr_bf->{ATM}) {
        $skew     = 4.4478 * $rr_bf->{RR_25} / $rr_bf->{ATM};
        $kurtosis = 52.7546 * $rr_bf->{BF_25} / $rr_bf->{ATM};

    } else {
        $skew     = '';
        $kurtosis = '';
    }

    return {
        skew     => $skew,
        kurtosis => $kurtosis
    };
}

=head1 rmg_text_format

Output the volatility surface in RMG text format.

=cut

sub rmg_text_format {
    my $self = shift;

    my $volsurface       = $self->surface;
    my $atm_spread_point = $volsurface->atm_spread_point;
    my @surface;

    my @surface_vol_point    = @{$volsurface->smile_points};
    my @surface_spread_point = @{$volsurface->spread_points};
    my @formated_surface_spread_point;
    my $vol_type;

    foreach my $delta (@surface_spread_point) {
        if ($delta =~ /^\d+/) {

            if ($volsurface->type eq 'delta') {
                push @formated_surface_spread_point, $delta . 'D_spread';
            } else {
                push @formated_surface_spread_point, $delta . 'M_spread';
            }

        } else {
            push @formated_surface_spread_point, $delta;
        }
    }

    push @surface, join $self->_field_separator, ('day', @surface_vol_point, @formated_surface_spread_point);

    foreach my $day (@{$volsurface->term_by_day}) {
        my $smile = $volsurface->get_smile($day);

        my $spread = $volsurface->get_smile_spread($day);
        my $row = $self->_construct_smile_line($day, $smile);

        if ($atm_spread_point ne 'atm_spread') {
            $spread = $spread->{'vol_spread'};
        }

        foreach my $spread_point (@surface_spread_point) {

            $row .= $self->_field_separator . $spread->{$spread_point};

        }

        push @surface, $row;
    }

    return @surface;
}

# Get the smile for specific day in a line format: day value1 value2 value3 ....
# Input: day
sub _construct_smile_line {
    my ($self, $day, $smile_ref) = @_;

    my $volsurface = $self->surface;

    my @surface_vol_point;
    my $vol_type;
    if ($volsurface->type eq 'delta') {
        @surface_vol_point = @{$volsurface->deltas};
        $vol_type          = 'delta';

    } elsif ($volsurface->type eq 'moneyness') {
        @surface_vol_point = @{$volsurface->moneynesses};
        $vol_type          = 'moneyness';
    }

    my %deltas_to_use = map { $_ => 1 } @surface_vol_point;

    $day = $volsurface->surface->{$day}->{tenor} || $day;

    my @smile_line = ($day);

    foreach my $point (sort { $a <=> $b } keys %{$smile_ref}) {
        next if not $deltas_to_use{$point};
        my $output =
            ($self->_output_format)
            ? sprintf($self->_output_format, $smile_ref->{$point})
            : $smile_ref->{$point};
        push @smile_line, $output;
    }

    return join $self->_field_separator, @smile_line;
}

=head1 html_volsurface_in_table

=cut

sub html_volsurface_in_table {
    my ($self, $args) = @_;
    my $class = $args->{class};

    my $surface = $self->surface;
    my @volatility_type;
    my @spreads_points = @{$surface->spread_points};

    my @days = @{$surface->original_term_for_smile};
    if ($surface->type eq 'delta') {
        @volatility_type = @{$surface->deltas};
    } elsif ($surface->type eq 'moneyness') {
        @volatility_type = @{$surface->moneynesses};
    }

    $class = $class ? ' class="' . $class . '"' : '';

    my $output = '<table' . $class . ' border="1">';
    $output .= '<tr>';
    $output .= '<th>Day</th>';
    foreach my $vol_point (sort { $a <=> $b } @volatility_type) {

        $output .= "<th>$vol_point</th>";
    }
    foreach my $delta (@spreads_points) {
        if ($delta =~ /^\d+/) {
            if ($surface->type eq 'delta') {
                $output .= '<th>' . $delta . 'D_spread' . '</th>';
            } else {
                $output .= '<th>' . $delta . 'M_spread' . '</th>';
            }

        } else {
            $output .= '<th>' . $delta . '</th>';
        }
    }

    $output .= '</tr>';

    foreach my $day (@days) {
        my $smile  = $surface->surface->{$day};
        my $spread = $surface->get_smile_spread($day);

        $output .= '<tr>';
        $output .= "<td>$day</td>";

        foreach my $vol_point (sort { $a <=> $b } @volatility_type) {

            # Argh! jsonify's separator is a "."; not so good if you
            # have a number with potentially a decimal point as a key.
            my $hacked_vol_point = $vol_point;
            $hacked_vol_point =~ s/\./point/g;

            my $vol = roundnear(0.0001, $smile->{smile}->{$vol_point});

            $output .= "<td data-jsonify-name=\"$day.smile.$hacked_vol_point\" data-jsonify-getter=\"anything\">$vol</td>";
        }

        foreach my $spread_point (@spreads_points) {

            my $hacked_spread_point = $spread_point;
            $hacked_spread_point =~ s/\./point/g;

            my $display_spread;
            if ($spread_point eq 'atm_spread') {
                $display_spread = roundnear(0.0001, $spread->{$spread_point});
            } else {

                $display_spread = roundnear(0.0001, $spread->{vol_spread}->{$spread_point});
            }

            $output .= "<td data-jsonify-name=\"$day.vol_spread.$hacked_spread_point\" data-jsonify-getter=\"anything\">$display_spread</td>";

        }

        $output .= "</tr>";
    }
    $output .= "</table>";

    return $output;
}

=head1 print_comparison_between_volsurface

compare and print two vol surfaces
will return number of big differences found

=cut

sub print_comparison_between_volsurface {
    my ($self, $args) = @_;

    my ($ref_surface, $warn_diff, $quiet, $ref_surface_source, $surface_source) =
        @{$args}{qw( ref_surface warn_diff quiet ref_surface_source surface_source )};

    return 'Comparison failed because existing surface does not exist'
        unless $ref_surface;
    my $surface = $self->surface;

    $ref_surface_source ||= "USED";
    $surface_source     ||= "NEW";

    my @days = @{$surface->original_term_for_smile};
    my @column_names;
    my $vol_type = $surface->type;

    if ($vol_type eq 'moneyness') {
        $surface->{price_with_parameterized_surface}     = 0;
        $ref_surface->{price_with_parameterized_surface} = 0;

    }

    my @surface_vol_point = $vol_type eq 'delta' ? @{$surface->deltas} : @{$surface->moneynesses};
    my @surface_spread_point = @{$surface->spread_points};

    push @column_names, (@surface_vol_point, @surface_spread_point);

    my $count_cols = scalar @column_names;
    my $count_rows = scalar @days;

    my $found_big_difference = 0;
    my $big_diff_msg;

    my @output;

    push @output, "<TABLE width=100% BORDER=2 bgcolor=#00AAAA>";
    push @output, "<TR>";
    push @output, '<TH> Days </TH>';
    foreach my $Col_point (sort { $a <=> $b } @surface_vol_point) {

        push @output, "<TH> $Col_point</TH>";
    }

    foreach my $spread_point (sort { $a <=> $b } @surface_spread_point) {

        push @output, "<TH> $spread_point" . '_spread' . "</TH>";
    }

    push @output, "</TR>";
    for (my $i = 0; $i < $count_rows; $i++) {
        push @output, "<TR>";
        push @output, "<TH>$days[$i]</TH>";
        foreach my $col_point (sort { $a <=> $b } @surface_vol_point) {

            my $vol = roundnear(
                0.0001,
                $surface->get_volatility({
                        days      => $days[$i],
                        $vol_type => $col_point
                    }));
            my $ref_vol = roundnear(
                0.0001,
                $ref_surface->get_volatility({
                        days      => $days[$i],
                        $vol_type => $col_point
                    }));

            my $vol_picture =
                (abs($vol - $ref_vol) < 0.001)
                ? ''
                : (($vol > $ref_vol) ? 'change_up_1.gif' : 'change_down_1.gif');

            my $volpoint_diff   = abs($vol - $ref_vol);
            my $percentage_diff = $volpoint_diff / $ref_vol * 100;
            my $big_difference  = ($volpoint_diff > 0.03 and $percentage_diff > 100) ? 1 : 0;

            if ($big_difference) {
                $found_big_difference++;
                $big_diff_msg =
                      'Big difference found on term['
                    . $days[$i]
                    . '] for point ['
                    . $col_point
                    . '] with absolute diff ['
                    . $volpoint_diff
                    . '] percentage diff ['
                    . $percentage_diff . ']';
            }

            my $bgcolor = ($big_difference) ? 'red' : '';
            my $html_picture_tag =
                $vol_picture
                ? "<img src=\"" . request()->url_for("images/pages/flash-charts/$vol_picture") . "\" border=0>"
                : '==';

            push @output, qq~<TD align="center" bgcolor="$bgcolor">$vol($surface_source) $html_picture_tag $ref_vol($ref_surface_source)</TD>~;
        }

        foreach my $spread_point (sort { $a <=> $b } @surface_spread_point) {

            my $ref_spread = roundnear(0.0001, $ref_surface->{'surface'}->{$days[$i]}->{'vol_spread'}->{$spread_point});
            my $spread     = roundnear(0.0001, $surface->{'surface'}->{$days[$i]}->{'vol_spread'}->{$spread_point});

            my $spread_picture =
                (abs($spread - $ref_spread) < 0.001) ? ''
                : (
                ($spread > $ref_spread) ? 'change_up_1.gif'
                : 'change_down_1.gif'
                );
            my $html_picture_tag =
                $spread_picture
                ? "<img src=\"" . request()->url_for("images/pages/flash-charts/$spread_picture") . "\" border=0>"
                : '==';

            push @output, qq~<TD align="center" >$spread ($surface_source) $html_picture_tag $ref_spread ($ref_surface_source)</TD>~;

        }
    }
    push @output, "</TR>";
    push @output, "</TABLE>";

    if (not $quiet) {
        foreach my $line (@output) {
            print $line;
        }
    }

# return the number of big differences and the number of total difference at all in the volsurface:
    return ($found_big_difference, $big_diff_msg, @output);
}

=head1 plot_smile_or_termstructure

=cut

sub plot_smile_or_termstructure {
    my ($self, $setup) = @_;

    my $surface = $self->surface;
    my $exist = try { $surface->surface };

    return 'VolSurface does not exist' unless $exist;

    my @surface_vol_point;
    my $vol_type;
    if ($surface->type eq 'delta') {
        @surface_vol_point = @{$surface->deltas};
        $vol_type          = 'delta';

    } elsif ($surface->type eq 'moneyness') {
        @surface_vol_point = @{$surface->moneynesses};
        $vol_type          = 'moneyness';
    }

    my $days_to_expiry_fix = $setup->{days_to_expiry};
    my $moneyness_fix      = $setup->{moneyness};
    my $x_label            = $setup->{x_label};
    my $top_title          = $setup->{title};

    my @data_to_plot;

    # Plot a Smile By Moneyness For Fixed Time To expiry
    if ($days_to_expiry_fix) {
        foreach my $moneyness (sort { $a <=> $b } @surface_vol_point) {
            push @data_to_plot,
                (
                $moneyness . ' '
                    . 100 * $surface->get_volatility({
                        days      => $days_to_expiry_fix,
                        $vol_type => $moneyness,
                    }));
        }
    }

    # Plot Termstructure For Fixed Moneyness
    else {
        foreach my $day_to_expiry (@{$surface->term_by_day}) {
            push @data_to_plot,
                (
                $day_to_expiry . ' '
                    . 100 * $surface->get_volatility({
                        days      => $day_to_expiry,
                        $vol_type => $moneyness_fix,
                    }));
        }
    }
    my $data = join "\n", @data_to_plot;

    if (not $top_title) {
        $top_title = $days_to_expiry_fix ? 'Smile' : 'Termstructure';
    }

    my ($file_name, $dir) = ('volsurface_' . int(rand(1000)) . '.png', BOM::Platform::Runtime->instance->app_config->system->directory->tmp_gif);
    my $file           = "$dir/$file_name";
    my $graphs_gnuplot = BOM::Utility::GNUPlot->new({
        top_title       => $top_title,
        x_label         => $x_label,
        y_label         => 'Volatility',
        x_format        => '%.0f',
        y_format        => '%.1f',
        legend_border   => 'box',
        legend_position => 'out horiz bot right',
        graph_size      => '400,300',
        output_file     => $file,
    });

    $graphs_gnuplot->set_data_properties({
        using      => '1:2',
        title      => 'volatility',                        # will be shown as an item in the legend box
        graph_type => 'lines',
        line_style => 'lw 2 pt 1 ps 1 lc rgb "#00B900"',
        fill_style => 'solid 0.2 noborder',
        data       => $data,
    });

    $graphs_gnuplot->plot();
    my $source = request()->url_for('temp/' . $file_name);

    return "<img border=0 src=\"$source\">";
}

sub calculate_moneyness_vol_for_display {
    my $self = shift;

    my $volsurface = $self->surface;
    my $fv         = $self->get_forward_vol();
    my @surface;

    foreach my $term (@{$volsurface->original_term_for_smile}) {
        my @row;
        next if $term > 366;

        #my @headers = qw(days date forward_vol RR 2vBF 1vBF skew kurtosis);
        push @row, 100 * roundnear(0.0001, $fv->{$term});

        my %delta_smile = map { $_ => $volsurface->get_volatility({delta => $_, days => $term}) } qw(25 50 75);
        my $rr_bf = $volsurface->get_rr_bf_for_smile(\%delta_smile);
        push @row, roundnear(0.0001, $rr_bf->{RR_25});
        push @row, roundnear(0.0001, $rr_bf->{BF_25});
        my $vol1_bf = roundnear(
            0.0001,
            get_1vol_butterfly({
                    spot             => $volsurface->underlying->spot,
                    tiy              => $term / 365,
                    delta            => 0.25,
                    call_vol         => $delta_smile{25},
                    put_vol          => $delta_smile{75},
                    atm_vol          => $delta_smile{50},
                    bf_1vol          => 0,
                    r                => $volsurface->underlying->interest_rate_for($term / 365),
                    q                => $volsurface->underlying->dividend_rate_for($term / 365),
                    premium_adjusted => $volsurface->underlying->{market_convention}->{delta_premium_adjusted},
                    bf_style         => '2_vol',
                }));
        push @row, $vol1_bf;
        my $sk = $self->get_skew_kurtosis($rr_bf);
        push @row, roundnear(0.0001, $sk->{skew});
        push @row, roundnear(0.0001, $sk->{kurtosis});
        my $moneynesses = $volsurface->moneynesses;
        my $smile       = $volsurface->surface->{$term}->{smile};
        my @rounded_vol =
            map { 100 * roundnear(0.0001, $smile->{$_}) } @$moneynesses;
        push @row, @rounded_vol;
        push @surface, [@row];
    }

    return @surface;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
