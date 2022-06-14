package BOM::Product::Offerings::TradingContract;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_contracts);

use LandingCompany::Registry;
use Date::Utility;
use Brands;

use BOM::Config::Runtime;
use BOM::Product::Exception;

=head2 get_contracts

Returns a array reference of contracts for a given symbol

=over 4

=item * symbol - underlying symbol. (required)

=item * landing_company_name - landing company short name. Default to 'virtual'

=item * country_code - 2-letter country code

=item * app_id - application id

=back

=cut

sub get_contracts {
    my $args = shift;

    my $symbol               = $args->{symbol}               // BOM::Product::Exception->throw(error_code => 'OfferingsSymbolRequired');
    my $landing_company_name = $args->{landing_company_name} // 'virtual';
    my $country_code         = $args->{country_code};
    my $brand                = $args->{brands} // Brands->new();
    my $app_id               = $args->{app_id};

    my $landing_company = LandingCompany::Registry->by_name($landing_company_name);

    BOM::Product::Exception->throw(error_code => 'OfferingsInvalidLandingCompany') unless $landing_company;

    my $app_offerings    = $brand->get_app($app_id)->offerings();
    my $offerings_config = BOM::Config::Runtime->instance->get_offerings_config();

    my $offerings_obj;
    if ($country_code) {
        $offerings_obj = $landing_company->basic_offerings_for_country($country_code, $offerings_config, $app_offerings);
    } else {
        $offerings_obj = $landing_company->basic_offerings($offerings_config, $app_offerings);
    }

    my @contracts = $offerings_obj->query({underlying_symbol => $symbol});

    BOM::Product::Exception->throw(error_code => 'OfferingsInvalidSymbol') unless (@contracts);

    return \@contracts;
}

1;
