package Test::BOM::ActiveSymbols;

use strict;
use warnings;

use LandingCompany::Offerings;
use LandingCompany::Registry;
use BOM::Config::Runtime;

sub get_active_symbols {
    my ($arr_contract_type, $arr_barrier_category) = @_;

    my $offerings               = _get_offerings();
    my $filterred_symbols_count = 0;

    foreach my $symbol (keys %$offerings) {
        my $offering = $offerings->{$symbol};

        $filterred_symbols_count++ if (_matches_criteria($arr_contract_type, $arr_barrier_category, $offering));
    }
    return $filterred_symbols_count;
}

sub _get_offerings {
    my ($lc_name) = @_;

    my $runtime         = BOM::Config::Runtime->instance;
    my $landing_company = LandingCompany::Registry->by_name('virtual');
    my $app_offerings   = "default";
    my $config          = $runtime->get_offerings_config;
    my $legal_offerings = $landing_company->legal_allowed_offerings();
    $config->{legal_allowed_offerings} = $legal_offerings;
    my $landing_company_name = $landing_company->short;

    # An instance of LandingCompany::Offerings Class
    my $landing_company_offerings = LandingCompany::Offerings->get({
        name     => $landing_company_name,
        filename => $landing_company->offerings->{basic}{default},
        app      => $app_offerings,
        config   => $config
    });

    # Offerings key (a json contains all symbols|offerings) of LandingCompany::Offerings
    my $offerings = $landing_company_offerings->offerings;
    return $offerings;
}

# Search for symbols by a combination of contract_type and barrier_category
sub _matches_criteria {
    my ($arr_contract_type, $arr_barrier_category, $offering) = @_;

    my $contract_type_config = Finance::Contract::Category::get_all_contract_types();

    if (defined $arr_contract_type) {
        foreach my $contract (@$arr_contract_type) {
            if (ref($offering) eq 'HASH') {
                foreach my $key_offering (keys %$offering) {
                    if ($key_offering eq $contract_type_config->{$contract}{category}) {
                        if (defined $arr_barrier_category) {
                            return _has_barrier_category($arr_barrier_category, $offering->{$key_offering});
                        } else {
                            return 1;
                        }
                    }
                }
            }
        }
    }
    if (defined $arr_barrier_category && !defined $arr_contract_type) {
        return _has_barrier_category($arr_barrier_category, $offering);
    }

    return 0;
}

sub _has_barrier_category {
    my ($arr_barrier_category, $offering) = @_;
    foreach my $barrier (@$arr_barrier_category) {
        if (ref($offering) eq 'HASH') {
            foreach my $key (keys %$offering) {
                if ($key eq $barrier) {
                    return 1;
                } elsif (ref($offering->{$key}) eq 'HASH') {
                    my $result = _has_barrier_category($arr_barrier_category, $offering->{$key});
                    return 1 if $result;
                }
            }
        }
    }
    return 0;
}

1;
