package BOM::RPC::v3::MarketDiscovery;

use strict;
use warnings;

use BOM::RPC::Registry '-dsl';

use BOM::User::Client;
use BOM::Platform::Context                   qw (localize request);
use List::UtilsBy                            qw(sort_by);
use BOM::Product::Offerings::TradingSymbol   qw(get_symbols);
use BOM::Product::Offerings::TradingContract qw(get_contracts get_unavailable_contracts);
use BOM::Product::ContractFinder::Basic;

rpc active_symbols => sub {
    my $params = shift;

    my $args = _extract_params($params);
    $args->{type}             = $params->{args}->{active_symbols};
    $args->{contract_type}    = $params->{args}->{contract_type};
    $args->{barrier_category} = $params->{args}->{barrier_category};

    my $res = get_symbols($args);

    my @active_symbols =
        map {
        $_->{display_name}           = localize($_->{display_name});
        $_->{market_display_name}    = localize($_->{market_display_name});
        $_->{submarket_display_name} = localize($_->{submarket_display_name});
        $_->{subgroup_display_name}  = localize($_->{subgroup_display_name});
        $_
        } sort_by { $_->{display_name} =~ s{([0-9]+)}{sprintf "%-09.09d", $1}ger } $res->{symbols}->@*;

    return \@active_symbols;
};

rpc contracts_for => sub {
    my $params = shift;

    # landing_company is deprecated to make place for landing_company_short.
    # We need to here some special handling for these parameters as they both default to virtual
    # TODO: Remove this line when we remove the deprecated landing_company.
    my $lc = $params->{args}->{landing_company};
    $params->{args}->{landing_company_short} = $lc if $lc && $lc ne 'virtual';

    my $args = _extract_params($params);
    $args->{symbol} = $params->{args}->{contracts_for};

    my $offerings = get_contracts($args);

    my $non_available_offerings = get_unavailable_contracts({
            offerings            => $offerings,
            symbol               => $args->{symbol},
            app_id               => $args->{app_id},
            brands               => $args->{brands},
            country_code         => $args->{country_code},
            landing_company_name => $args->{landing_company_name}});

    my $contracts_for = BOM::Product::ContractFinder::Basic::decorate({
        offerings               => $offerings,
        non_available_offerings => $non_available_offerings,
        %$args,
    });

    my $i = 0;
    foreach my $contract (@{$contracts_for->{available}}) {
        # localise contract *_display
        if ($contracts_for->{available}->[$i]->{contract_category_display}) {
            $contracts_for->{available}->[$i]->{contract_category_display} = localize($contracts_for->{available}->[$i]->{contract_category_display});
        }

        if ($contracts_for->{available}->[$i]->{contract_display}) {
            $contracts_for->{available}->[$i]->{contract_display} = localize($contracts_for->{available}->[$i]->{contract_display});
        }
        $i++;
    }

    my $count = 0;
    foreach my $contract (@{$contracts_for->{non_available}}) {
        # localise non_available_contract *_display and categories
        $contracts_for->{non_available}->[$count]->{contract_display_name} =
            localize($contracts_for->{non_available}->[$count]->{contract_display_name})
            if $contracts_for->{non_available}->[$count]->{contract_display_name};

        $contracts_for->{non_available}->[$count]->{contract_category} = localize($contracts_for->{non_available}->[$count]->{contract_category})
            if $contracts_for->{non_available}->[$count]->{contract_category};
        $count++;
    }

    return $contracts_for;
};

=head2 _extract_params

Extra parameters for RPC endpoint

=cut

sub _extract_params {
    my $params = shift;

    my $landing_company_name = $params->{args}->{landing_company_short} // $params->{args}->{landing_company};
    my $token_details        = $params->{token_details};
    my $country_code         = $params->{country_code};
    my $app_id               = $params->{valid_source} // $params->{source};

    if ($token_details and exists $token_details->{loginid}) {
        my $client = BOM::User::Client->new({
            loginid      => $token_details->{loginid},
            db_operation => 'replica'
        });

        $landing_company_name = $client->landing_company->short;
        $country_code         = $client->residence;
    }

    return {
        landing_company_name => $landing_company_name,
        country_code         => $country_code,
        app_id               => $app_id,
        brands               => request()->brand,
    };
}

1;
