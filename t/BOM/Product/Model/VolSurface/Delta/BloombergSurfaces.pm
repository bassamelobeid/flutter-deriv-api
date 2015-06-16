package BloombergSurfaces;

use strict;
use warnings;

use Moose;
use File::Basename qw( dirname );
use Cwd qw( abs_path );
use File::Find;
use IO::File;
use Text::CSV;

use BOM::Market::Underlying;
use Date::Utility;

use BOM::MarketData::VolSurface::Cutoff;

sub get {
    my ($self, $symbol, $timestamp, $cutoff) = @_;
    my $surface;

    if (not $cutoff and scalar keys %{$self->surfaces->{$symbol}->{$timestamp}} == 1) {
        my @surfaces = values %{$self->surfaces->{$symbol}->{$timestamp}};
        $surface = $surfaces[0];
    } else {
        $surface = $self->surfaces->{$symbol}->{$timestamp}->{$cutoff};
    }

    return $surface;
}

has relative_data_dir => (
    is      => 'ro',
    isa     => 'Str',
    default => '.',
);

=head1 surfaces

All surfaces, grabbed from Bloomberg, that this module can find.

Sources are either CSV files exported directly from Bloomberg and
located in the same directory as the packages source file.

=cut

has surfaces => (
    is         => 'ro',
    isa        => 'HashRef',
    init_arg   => undef,
    lazy_build => 1,
);

sub _build_surfaces {
    my $self         = shift;
    my $all_surfaces = {};

    my @filenames;
    my $wanted = sub {
        my $f = $File::Find::name;
        push @filenames, $f if ($f =~ /\.csv$/);
    };

    # look for CSV files in the directory of the executing script.
    find($wanted, abs_path(dirname($0)) . '/' . $self->relative_data_dir);

    foreach my $filename (@filenames) {
        my @surfaces = $self->_get_surfaces_from_file($filename);

        foreach my $s (@surfaces) {
            $all_surfaces->{$s->underlying->symbol}->{$s->recorded_date->datetime_yyyymmdd_hhmmss}->{$s->cutoff->code} = $s;
        }
    }

    return $all_surfaces;
}

sub _get_surfaces_from_file {
    my ($self, $filename) = @_;

    die "Invalid filename [$filename]" if ($filename !~ /_(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\.csv$/);
    my $timestamp    = "$1-$2-$3 $4:$5:$6";
    my $surface_date = Date::Utility->new($timestamp);

    my $fh = IO::File->new;
    $fh->open($filename, 'r');

    my $csv = Text::CSV->new;
    my @surfaces;

    ROW:
    while (my $row = $csv->getline($fh)) {

        my $symbol;
        if (length $row->[0] == 3 and length $row->[1] == 3) {
            $symbol = 'frx' . $row->[0] . $row->[1];
        } elsif (
            $row->[0] and not grep {
                $row->[$_]
            } (1 .. (scalar @{$row})))
        {
            $symbol = $row->[0];
        }

        next ROW if (not $symbol);

        my $underlying = BOM::Market::Underlying->new($symbol);
        my $cutoff = $row->[4] ? BOM::MarketData::VolSurface::Cutoff->new($row->[4]) : undef;

        # skip past the two "config" lines; they don't tell
        # us anything we don't already know.
        $csv->getline($fh);
        $csv->getline($fh);

        my $surface_data = {};

        SMILE:
        while (my $smile = $csv->getline($fh)) {

            # break out of CSV line empty.
            last SMILE if (not grep { $_ } @{$smile});

            my ($maturity, $unit) = ($smile->[0] =~ /(\d+)([DWMY])/);
            my $multiplier = $unit eq 'W' ? 7 : $unit eq 'M' ? 30 : $unit eq 'Y' ? 365 : 1;
            $maturity *= $multiplier;
            $maturity = 'ON' if ($maturity == 1);

            $surface_data->{$maturity} = {
                smile => {
                    25 => ($smile->[3] / 100),
                    50 => ($smile->[1] / 100),
                    75 => ($smile->[5] / 100),
                },
                vol_spread => {
                    50 => ($smile->[2] / 100),
                },
            };
        }

        my $args = {
            underlying      => $underlying,
            recorded_date   => $surface_date,
            print_precision => undef,
            deltas          => [25, 50, 75],
            surface         => $surface_data,
            market_points   => {
                smile      => ['ON', 7, 14, 21, 30, 60, 90, 120, 150, 180, 270, 365],
                vol_spread => ['ON', 7, 14, 21, 30, 60, 90, 120, 150, 180, 270, 365],
            },
        };

        $args->{cutoff} = $cutoff if $cutoff;

        push @surfaces, BOM::MarketData::VolSurface::Delta->new($args);
    }

    return @surfaces;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
