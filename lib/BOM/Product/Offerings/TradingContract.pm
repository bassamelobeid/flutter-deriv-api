package BOM::Product::Offerings::TradingContract;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_contracts get_unavailable_contracts);

use LandingCompany::Registry;
use Date::Utility;
use Brands;

use BOM::Config::Runtime;
use BOM::Product::Exception;
use Finance::Contract::Category;
use Finance::Underlying;
use List::Util    qw(uniq);
use JSON::MaybeXS qw(decode_json);

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

    my $symbol        = $args->{symbol} // BOM::Product::Exception->throw(error_code => 'OfferingsSymbolRequired');
    my $offerings_obj = _get_offerings($args);
    my @contracts     = $offerings_obj->query({underlying_symbol => $symbol});

    BOM::Product::Exception->throw(error_code => 'OfferingsInvalidSymbol') unless (@contracts);

    return \@contracts;
}

=head2 _get_offerings

returns all the offerings for a particular landing company, country, brand and app tupple.

Takes the following arguments as named parameters:

=over 4

=item * C<landing_company_name> - the name of the landing company, defaults to 'virtual'

=item * C<country_code> - country code

=item * C<brands> - brand

=item * C<app_id> - application id

=back

Returns a L<LandingCompany::Offerings> object containing all the available
offerings for the given parameters in case of success and throws an exception
in case of failure.

=cut

sub _get_offerings {
    my $args = shift;

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

    return $offerings_obj;
}

=head2 get_unavailable_contracts

Returns a array reference of unavailable contracts for a given symbol

=cut

sub get_unavailable_contracts {
    my $args = shift;

    my $symbol            = $args->{symbol} // BOM::Product::Exception->throw(error_code => 'OfferingsSymbolRequired');
    my $offerings_obj     = _get_offerings($args);
    my %av_contract_types = map  { $_ => 1 } uniq $offerings_obj->query({underlying_symbol => $symbol}, ['contract_type']);
    my @na_contract_types = grep { !$av_contract_types{$_} } $offerings_obj->values_for_key('contract_type');

    my $contract_types = Finance::Contract::Category::get_all_contract_types();

    # temporarily disabling 1(s) indices for accumulator on Real accounts for ROW
    push @na_contract_types, "ACCU" if $symbol =~ /1HZ.*V$/ && $args->{landing_company_name} =~ /svg/;

    my @result;

    # creating data for all_contract_types
    foreach my $contract_type (@na_contract_types) {
        if (exists $contract_types->{$contract_type}{display_name}) {
            my %record = (
                "contract_type"         => $contract_type,
                "contract_display_name" => $contract_types->{$contract_type}{display_name},
                "contract_category"     => $contract_types->{$contract_type}{category},
            );

            push @result, \%record;
        }
    }
    return \@result;
}

1;
