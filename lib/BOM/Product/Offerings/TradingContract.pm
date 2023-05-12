package BOM::Product::Offerings::TradingContract;

use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK = qw(get_contracts get_unavailable_contracts get_offerings_obj virtual_offering_based_on_country_code);

use LandingCompany::Registry;
use Date::Utility;
use Brands;

use BOM::Config::Runtime;
use BOM::Product::Exception;
use Finance::Contract::Category;
use Finance::Underlying;
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

=head2 get_unavailable_contracts

Returns a array reference of unavailable contracts for a given symbol

=cut

sub get_unavailable_contracts {
    my $args = shift;

    my ($symbol, $offerings) = @{$args}{'symbol', 'offerings'};
    my $landing_company_name = $args->{landing_company_name} // 'virtual';

    # If landing company name is svg it will change it to virtual to get complete superset of contract_types
    # superset = virtual + svg (we are only offering mulitpliers for 'maltainvest')
    if ($landing_company_name ne "virtual") {
        $landing_company_name = $landing_company_name eq 'svg' ? 'virtual' : 'maltainvest';
    }

    my $landing_company = LandingCompany::Registry->by_name($landing_company_name);

    # market of current underlying_symbol
    my $ul        = Finance::Underlying->by_symbol($symbol);
    my $ul_market = $ul->{market};

    my $contract_types = Finance::Contract::Category::get_all_contract_types();
    my @contract_type_names;

    # creating data for all_contract_types
    foreach my $key (keys %{$contract_types}) {
        if (exists $contract_types->{$key}{display_name}) {
            my %record = (
                "contract_type"         => $key,
                "contract_display_name" => $contract_types->{$key}{display_name},
                "contract_category"     => $contract_types->{$key}{category},
            );

            push @contract_type_names, \%record;
        }
    }

    my $offerings_obj = get_offerings_obj($args);

    # filtering out available non_available contract types from the all_contract_types
    my %available_contracts          = map  { $_->{contract_type} => $_ } @$offerings;
    my @non_available_contract_types = grep { !defined $available_contracts{$_->{contract_type}} } @contract_type_names;

    my %legal_allowed_offerings =
        $offerings_obj->{name} =~ /virtual_/
        ? virtual_offering_based_on_country_code($offerings_obj)
        : get_legal_allowed_offering($landing_company, $ul_market);
    @non_available_contract_types = grep { $legal_allowed_offerings{$_->{contract_category}} } @non_available_contract_types;

    # filtering out no_business from unavailable contract_category
    my $unavailable_contracts_list = filtering_no_business_contracts_category({unavailable => \@non_available_contract_types, symbol => $symbol});
    return $unavailable_contracts_list;
}

=head2 filtering_no_business_contracts_category

Return the filtered unavailable array based on risk_profile = no_business

=cut

sub filtering_no_business_contracts_category {
    my $args = shift;
    my ($symbol, $unavailable) = @{$args}{'symbol', 'unavailable'};

    my $app_config              = BOM::Config::Runtime->instance->app_config;
    my $custom_product_profiles = $app_config->get('quants.custom_product_profiles');
    my $data                    = decode_json($custom_product_profiles);
    my (%no_business_data, @split_string);

    for my $value (keys %{$data}) {
        if ($data->{$value}{risk_profile} && $data->{$value}{risk_profile} eq "no_business") {
            if ($data->{$value}{underlying_symbol} && $data->{$value}{underlying_symbol} eq $symbol && $data->{$value}{contract_category}) {
                @split_string = split(/,/, $data->{$value}{contract_category});
                $no_business_data{$_} = 1 for @split_string;
            }
        }
    }

    @$unavailable = grep { !$no_business_data{$_->{contract_category}} } @$unavailable;
    return $unavailable;
}

=head2 get_legal_allowed_offering

Return the legal allowed offering based on landing company.

=cut

sub get_legal_allowed_offering {
    my ($landing_company, $ul_market) = @_;

    my $legal_offerings = $landing_company->{legal_allowed_offerings}->{$ul_market};
    return map { $_ => 1 } @$legal_offerings;
}

=head2 virtual_offering_based_on_country_code

Return virtual offerings based on country code.

=cut

sub virtual_offering_based_on_country_code {
    my $virtual_offerings = shift;

    my %virtual_mf_offerings = ();
    my $data                 = $virtual_offerings->{offerings};
    for my $key (keys %{$data}) {
        my $k = $data->{$key};
        for my $offering (keys %{$k}) {
            # Set of legal offerings allowed based on country code.
            $virtual_mf_offerings{$offering} = 1;
        }
    }

    return %virtual_mf_offerings;
}

=head2 get_offerings_obj

return offerings object

=cut

sub get_offerings_obj {
    my $args = shift;

    my $brand                = $args->{brands} // Brands->new();
    my $app_id               = $args->{app_id};
    my $landing_company_name = $args->{landing_company_name} // 'virtual';
    my $country_code         = $args->{country_code};

    my $landing_company = LandingCompany::Registry->by_name($landing_company_name);

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

1;
