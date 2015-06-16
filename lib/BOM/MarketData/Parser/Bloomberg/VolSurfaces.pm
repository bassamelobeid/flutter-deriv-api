package BOM::MarketData::Parser::Bloomberg::VolSurfaces;

=head1 NAME

BOM::MarketData::Parser::Bloomberg::VolSurfaces

=head1 DESCRIPTION

This class ties together the aspects of fetching a vol surface from BBDL,
parsing the raw data and creating a vol model object.

=cut

use Moose;

use BOM::Market::Types;
use BOM::MarketData::VolSurface::Delta;
use Date::Utility;
use BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV;
use BOM::MarketData::Parser::Bloomberg::CSVParser::VolPoints;

=head1 ATTRIBUTES

=head2 flatten_ON

Whether or not to bring the ON smile's butterfly up to zero if it is negative.

=cut

has flatten_ON => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

=head2 parse_data_for

Returns a hash reference of volatility surfaces objects.

    my $data = BOM::MarketData::Parser::Bloomberg::VolSurfaces->new()->parse_data_for($file, $source);
=cut

sub parse_data_for {
    my ($self, $file, $source) = @_;
    my $date;

    if ($file =~ /quantovol/) {
        $date = Date::Utility->new;
    } else {
        my ($day, $h, $m, $s) = $file =~ /\/(\d{4}-\d{2}-\d{2})\/fx(\d{2})(\d{2})(\d{2})_?(OVDV|vol_points)?\.csv$/;
        $date = Date::Utility->new($day . ' ' . $h . ':' . $m . ':' . $s);
    }
    my $parser =
        $source eq 'OVDV' ? 'BOM::MarketData::Parser::Bloomberg::CSVParser::OVDV' : 'BOM::MarketData::Parser::Bloomberg::CSVParser::VolPoints';
    my $volsurfaces;

    foreach my $param ($parser->new->extract_volsurface_params($file)) {
        _do_flatten_ON($param->{surface}) if ($self->flatten_ON);
        $param->{recorded_date} = $date;
        $volsurfaces->{$param->{underlying}->symbol} = BOM::MarketData::VolSurface::Delta->new($param);
    }
    return $volsurfaces;
}

# If the ON Butterfly is negative, bring it up to zero.
# Note: I added the _do_ to differentiate this from the flatten_ON attribute
sub _do_flatten_ON {
    my $surface_data = shift;

    if (   not exists $surface_data->{ON}
        or not exists $surface_data->{ON}->{smile}->{25}
        or not exists $surface_data->{ON}->{smile}->{75})
    {
        return;
    }

    my %raw = (
        '25D' => $surface_data->{ON}->{smile}->{25},
        '75D' => $surface_data->{ON}->{smile}->{75},
        'ATM' => $surface_data->{ON}->{smile}->{50},
    );

    my $RR = $raw{'25D'} - $raw{'75D'};
    my $BF = ($raw{'25D'} + $raw{'75D'}) / 2 - $raw{ATM};

    if ($BF < 0) {
        # these are the "delta from RR/BF" formulae, missing the BF
        # term since we are re-calculating with a BF of zero.
        $surface_data->{ON}->{smile} = {
            25 => ($raw{ATM} + 0.5 * $RR),
            50 => $raw{ATM},
            75 => ($raw{ATM} - 0.5 * $RR),
        };
    }

    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
