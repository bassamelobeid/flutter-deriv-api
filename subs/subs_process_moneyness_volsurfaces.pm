use strict 'vars';
use open qw[ :encoding(UTF-8) ];

use include_common_modules;
use Spreadsheet::ParseExcel;
use Date::Manip;
use JSON qw( to_json );
use BOM::Utility::Log4perl qw( get_logger );

use BOM::Market::UnderlyingDB;

use BOM::MarketData::Parser::SuperDerivatives::VolSurface;
use BOM::MarketData::Display::VolatilitySurface;
use Path::Tiny;

my @symbols_to_update = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market       => ['indices'],
    broker       => 'VRT',
    bet_category => 'ANY'
);

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

    my $surfaces = BOM::MarketData::Parser::SuperDerivatives::VolSurface->new->parse_data_for($filename, \@symbols_to_update);
    unlink $filename;

    return compare_uploaded_moneyness_surface($surfaces);
}

sub compare_uploaded_moneyness_surface {
    my $surfaces = shift;

    my @items;

    UNDERLYING:
    foreach my $symbol (@symbols_to_update) {
        my $item = {symbol => $symbol};
        my $volsurface = $surfaces->{$symbol};

        if ($volsurface) {
            $item->{SD_surface} = {
                table => BOM::MarketData::Display::VolatilitySurface->new(surface => $volsurface)->html_volsurface_in_table({class => 'SD'}),
                recorded_epoch => $volsurface->recorded_date->epoch,
                spot_reference => $volsurface->spot_reference,
            };

            my $existing = $volsurface->get_existing_surface;
            if ($existing) {
                eval {
                    my ($found_big_difference, undef, @comparison_output) =
                      BOM::MarketData::Display::VolatilitySurface->new(surface => $existing)->print_comparison_between_volsurface({
                            ref_surface        => $volsurface,
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

            if (!$volsurface->is_valid) {
                $item->{SD_surface}->{reason} = $volsurface->validation_error;
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
