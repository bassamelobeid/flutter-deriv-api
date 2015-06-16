package BOM::MarketData::Parser::Bloomberg::CSVParser::VolPoints;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::CSVParser::VolPoints

=cut

=head1 DESCRIPTION

Processes the response files in volpoints format from Bloomberg Data License.
Returns an array of hashrefs that contains params for volsurface creation

=cut

use Moose;
use Text::CSV::Slurp;
use Scalar::Util qw(looks_like_number);
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Market::Underlying;
use BOM::MarketData::Fetcher::VolSurface;

=head2 extract_volsurface_params

Returns array of params for volsurface creation.
    my $parser = BOM::MarketData::Parser::Bloomberg::CSVParser::VolPoints->new;
    my @params = $parser->extract_volsurface_params;

=cut

sub extract_volsurface_params {
    my ($self, $filename) = @_;

    my $logger = get_logger;
    my $csv = Text::CSV::Slurp->load(file => $filename);
    my $data;

    foreach my $line (@$csv) {
        my $underlying_symbol = substr $line->{SECURITIES}, 0, 6;
        if ($line->{'ERROR CODE'}) {
            $logger->logwarn('Surface[' . $line->{SECURITIES} . '] grabbed from Bloomberg has errors.');
            next;
        }

        if (not(looks_like_number($line->{PX_LAST}) and looks_like_number($line->{PX_BID}) and looks_like_number($line->{PX_ASK}))) {
            $logger->logwarn('Ticker provided by Bloomberg is not a number for underlying [' . $underlying_symbol . ']');
            next;
        }

        my $security = $line->{SECURITIES};
        my $vol      = $line->{PX_LAST} / 100;
        my $spread   = ($line->{PX_ASK} - $line->{PX_BID}) / 100;

        if ($security =~ /\w\w\w\w\w\wV(\w+)/) {
            my $term = $1;
            $data->{$underlying_symbol}->{smile}->{$term}->{ATM}  = $vol;
            $data->{$underlying_symbol}->{spread}->{$term}->{ATM} = $spread;
        } elsif ($security =~ /\w\w\w\w\w\w(\d+)R(\w+)/) {
            my $delta = $1;
            my $term  = $2;
            $data->{$underlying_symbol}->{smile}->{$term}->{$delta . 'RR'} = $vol;
        } elsif ($security =~ /\w\w\w\w\w\w(\d+)B(\w+)/) {
            my $delta = $1;
            my $term  = $2;
            $data->{$underlying_symbol}->{smile}->{$term}->{$delta . 'BF'} = $vol;
        } else {
            $logger->logwarn('ticker[' . $security . '] not recognized');
            next;
        }
    }

    my @params;

    foreach my $underlying_symbol (keys %$data) {
        my $underlying   = BOM::Market::Underlying->new('frx' . $underlying_symbol);
        my $surface_data = _get_surface_data($data->{$underlying_symbol}, $underlying);
        my $type         = 'delta';

        my $param = {
            underlying => $underlying,
            surface    => $surface_data,
            type       => 'delta',
        };
        push @params, $param;
    }

    return @params;
}

sub _get_surface_data {
    my ($data, $underlying) = @_;
    my $surface_vol = _process_smiles_spread($data, $underlying);
    if (scalar keys %{$surface_vol} == 2) {
        $surface_vol = _append_to_existing_surface($surface_vol, $underlying);
    }
    my %surface_data =
        map { $_ => {smile => $surface_vol->{$_}->{smile}, vol_spread => $surface_vol->{$_}->{vol_spread}} } keys %$surface_vol;

    return \%surface_data;
}

# Bloomberg construct the 25D call and 25D put from the mid and applied a constant price spread to workout the bid and ask price of the call and put.
# The constant spread is taken from price spread of ATM straddle at the same maturity.
# Since we can not obtain the market price of the ATM straddle, we had done backtesting on these data points,
# we found that the ratio between these data points are quite constant.
# From our data analysis, we found 0.7 seems to be a fine constant.

sub _process_smiles_spread {
    my ($vol_surf, $underlying) = @_;

    my $surface_vol;
    foreach my $term (keys %{$vol_surf->{smile}}) {
        $surface_vol->{$term}->{smile}->{'50'} = $vol_surf->{smile}->{$term}->{'ATM'};
        if ($underlying->quanto_only) {
            $surface_vol->{$term}->{smile}->{'25'} = $vol_surf->{smile}->{$term}->{'ATM'};
            $surface_vol->{$term}->{smile}->{'75'} = $vol_surf->{smile}->{$term}->{'ATM'};
        } else {
            $surface_vol->{$term}->{smile}->{'25'} =
                $vol_surf->{smile}->{$term}->{'ATM'} + $vol_surf->{smile}->{$term}->{'25RR'} / 2 + $vol_surf->{smile}->{$term}->{'25BF'};
            $surface_vol->{$term}->{smile}->{'75'} =
                $vol_surf->{smile}->{$term}->{'ATM'} - $vol_surf->{smile}->{$term}->{'25RR'} / 2 + $vol_surf->{smile}->{$term}->{'25BF'};
        }
        $surface_vol->{$term}->{vol_spread}->{'50'} = $vol_surf->{spread}->{$term}->{'ATM'};
        $surface_vol->{$term}->{vol_spread}->{'25'} = $vol_surf->{spread}->{$term}->{'ATM'} / 0.7;
        $surface_vol->{$term}->{vol_spread}->{'75'} = $vol_surf->{spread}->{$term}->{'ATM'} / 0.7;

    }

    return $surface_vol;
}

sub _append_to_existing_surface {
    my ($new_surface, $underlying) = @_;

    my $existing_surface = BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({
            underlying => $underlying,
            cutoff     => 'New York 10:00'
        })->surface;

    foreach my $term (keys %{$existing_surface}) {

        my $tenor = $existing_surface->{$term}->{tenor};

        if ($tenor ne 'ON' and $tenor ne '1W') {
            $new_surface->{$tenor} = $existing_surface->{$term};
        }
    }

    return $new_surface;

}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
