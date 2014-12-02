use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use include_common_modules;
use Spreadsheet::ParseExcel;
use Date::Manip;
use JSON qw( to_json );
use BOM::Utility::Log4perl qw( get_logger );

use BOM::Market::UnderlyingDB;
use BOM::MarketData::VolSurface::Validator;

use BOM::Market::DataSource::SuperDerivatives::SuperDerivativesParser;
use BOM::MarketData::Display::VolatilitySurface;
use BOM::MarketData::AutoUpdater::Indices;
use Path::Tiny;

sub upload_and_process_moneyness_volsurfaces {
    my $filetoupload = shift;

    # path to upload to
    my $loc  = BOM::Platform::Runtime->instance->app_config->system->directory->db;
    my $path = "$loc/vol";

    if (not -d $path) {
        Path::Tiny::path($path)->mkpath;
    }

    local $CGI::POST_MAX        = 1024 * 100 * 8;    # max 800K posts
    local $CGI::DISABLE_UPLOADS = 0;                 # enable uploads

    # error checks
    if ($filetoupload !~ /\.xls$/) {
        return "File '$filetoupload' is not in EXCEL format. Should end with '.xls'.";
    }

    my $filename = "$path/$filetoupload";

    local *NEWFILE;

    if (not open(NEWFILE, ">$filename")) {
        return "[$0] could not write to $filename '$!'.";
    }
    binmode(NEWFILE);

    # upload file
    my $filesize;
    local $\ = "";
    while (my $buff = <$filetoupload>) {
        print NEWFILE $buff;
        $filesize += length($buff);
    }
    close NEWFILE;

    my $surfaces = BOM::Market::DataSource::SuperDerivatives::SuperDerivativesParser->new(file => $filename);

    return ($surfaces, $filename);
}

sub compare_uploaded_moneyness_surface {
    my $surfaces = shift;

    my @symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
        market       => ['indices', 'stocks'],
        broker       => 'VRT',
        bet_category => 'ANY'
    );

    my @items;
    my $auto_updater = BOM::MarketData::AutoUpdater::Indices->new;

    UNDERLYING:
    foreach my $symbol (@symbols) {
        my $item = {symbol => $symbol};

        # For certain underlying such as IXIC, SZSECOMP, N150, they are using NDX, SSECOMP and N100 surfaces respectively.
        my $surface_symbol = $auto_updater->equivalent_volsurfaces->{$symbol} || $symbol;

        my $SD_surfaces = $surfaces->get_volsurface_for($surface_symbol);

        my $underlying = BOM::Market::Underlying->new($symbol);
        my $existing = eval { BOM::MarketData::Fetcher::VolSurface->new->fetch_surface({underlying => $underlying}) };

        if ($SD_surfaces->{success} or $SD_surfaces->{reason}) {
            $item->{SD_surface}->{table} =
              BOM::MarketData::Display::VolatilitySurface->new(surface => $SD_surfaces->{surface})->html_volsurface_in_table({class => 'SD'});
            $item->{SD_surface}->{recorded_epoch} = $SD_surfaces->{surface}->recorded_date->epoch;

            if ($auto_updater->use_rmg_data_for_spot_reference($symbol)) {
                my $ref_tick = $underlying->tick_at($SD_surfaces->{surface}->recorded_date->epoch);
                $item->{SD_surface}->{spot_reference} = ($ref_tick) ? $ref_tick->quote : $underlying->spot;
            } else {
                $item->{SD_surface}->{spot_reference} = $SD_surfaces->{surface}->spot_reference;
            }

            if ($existing) {
                eval {
                    my ($found_big_difference, undef, @comparison_output) =
                      BOM::MarketData::Display::VolatilitySurface->new(surface => $existing)->print_comparison_between_volsurface({
                            ref_surface        => $SD_surfaces->{surface},
                            warn_diff          => 0.03,
                            quiet              => 1,
                            ref_surface_source => 'SD',
                            surface_source     => 'Existing',
                      });
                    if ($found_big_difference) {
                        $item->{big_diff}         = 1;
                        $item->{big_diff_between} = 'Existing and SD';
                        $item->{comparison}       = join "", @comparison_output;
                    }
                };
                if (my $e = $@) {
                    my $err = ref $e ? $e->trace : $e;
                    $item->{big_diff}         = 1;
                    $item->{big_diff_between} = "Died while trying to check for bigdiff";
                    $item->{comparison}       = "Exception found: $err";
                    get_logger->warn("Exception caught while checking bigdiff for $symbol. Error: $err");
                }
            }

            if ($SD_surfaces->{reason}) {
                $item->{SD_surface}->{reason} = $SD_surfaces->{reason};
            }
        } else {
            $item->{SD_surface}->{reason} = "SD does not have moneyness surface for $symbol";
        }

        push @items, $item;
    }
    my $html;
    BOM::Platform::Context::template->process(
        'backoffice/updatevol/moneyness_comparison.html.tt',
        {
            items      => \@items,
            update_url => 'quant/update_vol.cgi'
        },
        \$html
    ) || die BOM::Platform::Context::template->error;

    return $html;
}

1;
