package BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV

=head1 DESCRIPTION

Processes the response files in OVDV format from Bloomberg Data License.
Returns an array of hashrefs that contains params for volsurface creation

=cut

use Moose;
use Text::CSV::Slurp;
use BOM::Utility::Log4perl qw( get_logger );

use BOM::Market::Underlying;
use BOM::MarketData::Parser::Bloomberg::RequestFiles;

=head2 extract_volsurface_params

Returns array of params for volsurface creation.
    my $parser = BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV->new;
    my @params = $parser->extract_volsurface_params;

=cut

sub extract_volsurface_params {
    my ($self, $filename) = @_;

    my $logger           = get_logger;
    my %bloomberg_to_rmg = BOM::MarketData::Parser::Bloomberg::RequestFiles->new->bloomberg_to_rmg;
    my $csv              = Text::CSV::Slurp->load(file => $filename);

    my @params;

    foreach my $line (@$csv) {
        if ($line->{'ERROR CODE'}) {
            $logger->logwarn('Surface[' . $line->{SECURITIES} . '] grabbed from Bloomberg has errors.');
            next;
        }

        my $rmg_symbol = $bloomberg_to_rmg{$line->{SECURITIES}};
        if (not $rmg_symbol) {
            # Only log when there appears to be a Bloomberg security without a mapped RMG symbol.
            $logger->logwarn('Bloomberg symbol[' . $line->{SECURITIES} . '] does not map to a local symbol.') if ($line->{SECURITIES});
            # But skip this line, regardless.
            next;
        }

        my $underlying = BOM::Market::Underlying->new($rmg_symbol);

        push @params,
            {
            underlying => $underlying,
            surface    => _get_surface_data($line, $underlying),
            type       => 'delta',
            };
    }

    return @params;
}

sub _get_surface_data {
    my ($data, $underlying) = @_;

    my $surface_vol = _process_smiles($data->{DFLT_VOL_SURF_MID}, $underlying);
    my $surface_spread = _process_spread($data->{DFLT_VOL_SURF_SPRD});
    my %surface_data =
        map { $_ => {smile => $surface_vol->{$_}->{smile}, vol_spread => $surface_spread->{$_}->{vol_spread}} } keys %$surface_vol;

    return \%surface_data;
}

sub _process_smiles {
    my ($vol_surf, $underlying) = @_;

    my @vol_data = split ';', $vol_surf;
    my $ATM_vol;
    my $surface_vol;

    for (my $i = 5; $i <= scalar @vol_data; $i += 10) {
        my $tenor = $vol_data[$i];
        $tenor = 'ON' if ($tenor eq '1D');

        # skips anything more than 1 year
        next if ($tenor =~ /(\d+)Y/ and $1 > 1);
        next if ($tenor =~ /(\d+)M/ and $1 > 12);

        my $raw_delta = $vol_data[$i + 4];
        my $vol       = $vol_data[$i + 8] / 100;

        $ATM_vol = $vol if ($raw_delta eq 'ATM');

        my $delta = 50;

        if ($raw_delta =~ /(\d+)D_(\w+)/) {
            my ($value, $type) = ($1, $2);

            # Throwing away everything except 25 and 50 deltas for now.
            next if ($value != 25 and $value != 50);

            $delta = ($type eq 'CALL') ? $value : 100 - $value;
        }

        if ($underlying->quanto_only) {
            $surface_vol->{$tenor}->{smile}->{$delta} = $ATM_vol;
        } else {
            $surface_vol->{$tenor}->{smile}->{$delta} = $vol;
        }
    }

    return $surface_vol;
}

sub _process_spread {
    my $vol_spread = shift;

    my @vol_spread_data = split ';', $vol_spread;
    my $surface_spread;

    for (my $i = 5; $i <= scalar @vol_spread_data; $i += 10) {
        my $tenor = $vol_spread_data[$i];
        $tenor = 'ON' if ($tenor eq '1D');
        my $delta = $vol_spread_data[$i + 4];

        my $RMG_delta = 50;

        if ($delta =~ /(\d+)D_(\w+)/) {
            my ($value, $type) = ($1, $2);

            # Throwing away everything except 25 and 50 deltas for now.
            next if ($value != 25 and $value != 50);

            $RMG_delta = ($type eq 'CALL') ? $value : 100 - $value;
        }

        # skips anything more than 1 year
        next if ($tenor =~ /(\d+)Y/ and $1 > 1);
        next if ($tenor =~ /(\d+)M/ and $1 > 12);

        my $vol_spread = $vol_spread_data[$i + 8] / 100;

        $surface_spread->{$tenor}->{vol_spread}->{$RMG_delta} = $vol_spread;
    }

    return $surface_spread;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
