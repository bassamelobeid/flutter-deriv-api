package BOM::MarketDataAutoUpdater::Indices;

=head1 NAME

BOM::MarketDataAutoUpdater::Indices

=head1 DESCRIPTION

Updates Index vols from a given .file file.

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
use SuperDerivatives::VolSurface;

has filename => (
    is => 'ro',
);

has input_market => (
    is => 'ro',
);

has file => (
    is         => 'ro',
    lazy_build => 1,
);

has uses_binary_spot => (
    is      => 'ro',
    default => sub {
        {
            STI      => 1,
            SZSECOMP => 1,
            BIST100  => 1,
        };
    },
);

# We have a bash script on Amazon which is intended to call SD macro to update vol of different underlying on the auto_upload.xls on hourly basis and copy the file to our dropbox.

sub _build_file {
    my $self     = shift;
    my $filename = $self->filename;
    my $url      = 'https://www.dropbox.com/s/yjl5jqe6f71stf5/auto_upload.xls?raw=1';
    my $file     = '/tmp/' . $filename;

    my $ua = Mojo::UserAgent->new->max_redirects(5);
    $ua->get($url)->result->content->asset->move_to($file);

    return $file;
}
has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my $self      = shift;
    my $market    = $self->input_market;
    my %skip_list = map { $_ => 1 } (@{BOM::Config::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol});

    my @symbols_to_update;

    # We still have some open position on cash indices, hence we need to get the vol update list from the suspend buy list.
    # We will clean up the code once all the cash indices open positions closed up
    if ($market eq 'indices') {
        # These are the cash indices that being disabled
        @symbols_to_update = grep { not $skip_list{$_} and create_underlying($_)->market->name eq 'indices' }
            (@{BOM::Config::Runtime->instance->app_config->get('quants.underlyings.suspend_buy')});
    }
    return \@symbols_to_update;
}

has surfaces_from_file => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_surfaces_from_file {
    my $self = shift;
    return SuperDerivatives::VolSurface->new->parse_data_for($self->file, $self->symbols_to_update);
}

sub run {
    my $self               = shift;
    my $surfaces_from_file = $self->surfaces_from_file;
    my %otc_list =
        map { $_ => 1 } grep { create_underlying($_)->submarket->is_OTC } create_underlying_db->get_symbols_for(
        market            => 'indices',
        contract_category => 'ANY',
        );

    foreach my $symbol (@{$self->symbols_to_update}) {
        unless ($surfaces_from_file->{$symbol}) {

            $self->report->{$symbol} = {
                success => 0,
                reason  => 'Surface Information missing from datasource for ' . $symbol,
            };
            next;
        }
        try {
            my $underlying     = create_underlying($symbol);
            my $raw_volsurface = $surfaces_from_file->{$symbol};
            if ($self->uses_binary_spot->{$symbol}) {
                $raw_volsurface->{spot_reference} = $underlying->tick_at($raw_volsurface->{creation_date}->epoch, {allow_inconsistent => 1})->quote;

            }
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
                    if (exists $otc_list{'OTC_' . $symbol}) {
                        my $otc         = create_underlying('OTC_' . $symbol);
                        my $otc_surface = $volsurface->clone({
                            underlying => $otc,
                        });
                        $otc_surface->save;
                    }
                    $volsurface->save;
                    $self->report->{$symbol}->{success} = 1;

                } else {

                    $self->report->{$symbol} = {
                        success => 0,
                        reason  => 'Term 7 is missing from datasource for ' . $symbol,
                    };
                }
            } else {
                my $calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader);
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
