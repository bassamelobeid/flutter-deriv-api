package BOM::MarketDataAutoUpdater::Indices;

=head1 NAME

BOM::MarketDataAutoUpdater::Indices

=head1 DESCRIPTION

Updates Index vols from a given .file file.

=cut

use Moose;
extends 'BOM::MarketDataAutoUpdater';

use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Platform::Runtime;
use BOM::MarketData qw(create_underlying_db);
use SuperDerivatives::VolSurface;
use Try::Tiny;
use File::Temp;
use Quant::Framework::VolSurface::Moneyness;

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

# We have a script on Amazon which will call SD macro to update vol of different underlying on the auto_upload.xls and auto_upload_stocks.xls on hourly basic and copy the file to our dropbox.

sub _build_file {
    my $self     = shift;
    my $filename = $self->filename;
    my $url =
        $filename eq 'auto_upload.xls'
        ? 'https://www.dropbox.com/s/yjl5jqe6f71stf5/auto_upload.xls?dl=0'
        : 'https://www.dropbox.com/s/1y0l7dakl8yg5jd/auto_upload_stocks.xls?dl=0';
    my $file = '/tmp/' . $filename;
    `wget -O $file $url > /dev/null 2>&1`;
    return $file;
}
has symbols_to_update => (
    is         => 'ro',
    lazy_build => 1,
);

sub _build_symbols_to_update {
    my $self      = shift;
    my $market    = $self->input_market;
    my %skip_list = map { $_ => 1 } (@{BOM::Platform::Runtime->instance->app_config->quants->underlyings->disable_autoupdate_vol});

    my @symbols_to_update;
    if ($market eq 'indices') {
        @symbols_to_update = grep { not $skip_list{$_} and $_ !~ /^OTC_/ } create_underlying_db->get_symbols_for(
            market            => 'indices',
            contract_category => 'ANY',
        );
        # forcing it here since we don't have offerings for the index.
        push @symbols_to_update, qw(FTSE IXIC BIST100 DJI);

    } else {
        @symbols_to_update = create_underlying_db->get_symbols_for(
            market            => 'stocks',
            contract_category => 'ANY',
            exclude_disabled  => 1,
            submarket         => ['india_otc_stock', 'us_otc_stock', 'uk_otc_stock', 'ge_otc_stock',]);
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
    my %otc_list           = map { $_ => 1 } create_underlying_db->get_symbols_for(
        market            => 'indices',
        submarket         => 'otc_index',
        contract_category => 'ANY',
    );

    foreach my $symbol (@{$self->symbols_to_update}) {
        if (not $surfaces_from_file->{$symbol}) {
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
                # We do not have feed of BIST100 cash index, hence it need to use the spot of OTC_BIST100
                $raw_volsurface->{spot_reference} =
                    $symbol eq 'BIST100'
                    ? create_underlying('OTC_BIST100')->tick_at($raw_volsurface->{recorded_date}->epoch, {allow_inconsistent => 1})->quote
                    : $underlying->tick_at($raw_volsurface->{recorded_date}->epoch, {allow_inconsistent => 1})->quote;

            }
            my $volsurface = Quant::Framework::VolSurface::Moneyness->new({
                underlying       => $underlying,
                recorded_date    => $raw_volsurface->{recorded_date},
                spot_reference   => $raw_volsurface->{spot_reference},
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
                surface          => $raw_volsurface->{surface},
            });
            if ($volsurface->is_valid) {
                if (exists $otc_list{'OTC_' . $symbol}) {
                    my $otc         = create_underlying('OTC_' . $symbol);
                    my $otc_surface = $volsurface->clone({
                        underlying => $otc,
                    });
                    if (exists $volsurface->{7}) {
                        $otc_surface->save;
                    } else {
                        $self->report->{$symbol} = {
                            success => 0,
                            reason  => 'Term 7 is missing from datasource for ' . $symbol,
                        };
                    }
                }

                if (exists $volsurface->{7}) {
                    $volsurface->save;
                } else {
                    $self->report->{$symbol} = {
                        success => 0,
                        reason  => 'Term 7 is missing from datasource for ' . $symbol,
                    };
                }
                $self->report->{$symbol}->{success} = 1;
            } else {
                $self->report->{$symbol} = {
                    success => 0,
                    reason  => $volsurface->validation_error,
                };
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
