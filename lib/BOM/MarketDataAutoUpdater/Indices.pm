package BOM::MarketDataAutoUpdater::Indices;

=head1 NAME

BOM::MarketDataAutoUpdater::Indices

=head1 DESCRIPTION


=cut

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use Mojo::UserAgent;
use Try::Tiny;
no indirect;

use Quant::Framework::VolSurface::Moneyness;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Config::Runtime;
use BOM::MarketData qw(create_underlying_db);
use Bloomberg::VolSurfaces::BVOL;

has update_for => (
    is       => 'ro',
    required => 1,
);

has filename => (
    is => 'ro',
);

has input_market => (
    is => 'ro',
);

has root_path => (
    is => 'ro',

);

has bloomberg_symbol_mapping => (
    is      => 'ro',
    default => sub {
        {
            'AEX'  => 'OTC_AEX',
            'AS51' => 'OTC_AS51',
            'CAC'  => 'OTC_FCHI',
            'DAX'  => 'OTC_GDAXI',
            'HSI'  => 'OTC_HSI',
            'INDU' => 'OTC_DJI',
            'NDX'  => 'OTC_NDX',
            'NKY'  => 'OTC_N225',
            'SMI'  => 'OTC_SSMI',
            'SPX'  => 'OTC_SPC',
            'SX5E' => 'OTC_SX5E',
            'UKX'  => 'OTC_FTSE'
        };
    },
);

has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my $self = shift;
    my %skip_list = map { $_ => 1 } (@{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol});

    my @indices = grep { !$skip_list{$_} } create_underlying_db->get_symbols_for(
        market            => ['indices'],
        contract_category => 'ANY',
    );

    return \@indices;
}

has surfaces_from_file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_surfaces_from_file {
    my $self = shift;
    my $vol_data = Bloomberg::VolSurfaces::BVOL->new->parser($self->update_for, $self->root_path);
    return $self->process_volsurface($vol_data);

}

sub process_volsurface {
    my ($self, $data) = @_;
    my $vol_surface;
    foreach my $underlying_symbol (keys %$data) {
        my $system_symbol = $self->bloomberg_symbol_mapping->{$underlying_symbol};
        if ($data->{$underlying_symbol}->{error}) {
            $self->report->{$system_symbol} = {
                success => 0,
                reason  => $data->{$underlying_symbol}->{error},
            };
            next;
        }
        my $underlying_raw_data = $data->{$underlying_symbol};
        my %surface_data =
            map { $_ => {smile => $underlying_raw_data->{$_}->{smile}, vol_spread => $underlying_raw_data->{$_}->{spread}} }
            grep { $_ ne 'volupdate_time' } keys %$underlying_raw_data;

        $vol_surface->{$system_symbol} = {
            surface       => \%surface_data,
            creation_date => $data->{$underlying_symbol}->{volupdate_time},
        };
    }

    return $vol_surface;
}

sub run {
    my $self               = shift;
    my $surfaces_from_file = $self->surfaces_from_file;

    my $calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);

    foreach my $symbol (@{$self->symbols_to_update}) {
        my $underlying = create_underlying($symbol);
        unless ($surfaces_from_file->{$symbol}) {

            $self->report->{$symbol} = {
                success => 0,
                reason  => 'Surface Information missing from datasource for ' . $symbol,
                }
                if $calendar->is_open($underlying->exchange);
            next;
        }
        try {
            my $raw_volsurface = $surfaces_from_file->{$symbol};
            $raw_volsurface->{spot_reference} = $underlying->tick_at($raw_volsurface->{creation_date}->epoch, {allow_inconsistent => 1})->quote;
            my $volsurface = Quant::Framework::VolSurface::Moneyness->new({
                underlying       => $underlying,
                creation_date    => $raw_volsurface->{creation_date},
                spot_reference   => $raw_volsurface->{spot_reference},
                chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
                surface          => $raw_volsurface->{surface},
            });
            if ($volsurface->is_valid) {
                if (exists $volsurface->surface->{7}) {
                    $volsurface->save;
                    $self->report->{$symbol}->{success} = 1;

                } else {

                    $self->report->{$symbol} = {
                        success => 0,
                        reason  => 'Term 7 is missing from datasource for ' . $symbol,
                    };
                }
            } else {
                if ($calendar->is_open($underlying->exchange)) {
                    # Ignore all error when exchange is closed.
                    $self->report->{$symbol} = {
                        success => 0,
                        reason  => $volsurface->validation_error,
                    };
                }
            }

        }
        catch {
            # if it dies, catch it here.
            $self->report->{$symbol} = {
                success => 0,
                reason  => $_,
            };
        };
    }
    $self->SUPER::run();
    return 1;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
