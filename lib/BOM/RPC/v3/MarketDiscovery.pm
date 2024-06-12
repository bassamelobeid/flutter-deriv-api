package BOM::RPC::v3::MarketDiscovery;

use strict;
use warnings;

use BOM::Config::Chronicle;
use BOM::Platform::Context                   qw(localize request);
use BOM::Product::ContractFinder::Basic      qw(decorate decorate_brief);
use BOM::Product::Offerings::TradingContract qw(get_all_contracts get_contracts get_unavailable_contracts);
use BOM::Product::Offerings::TradingSymbol   qw(get_symbols);
use BOM::RPC::Registry '-dsl';
use BOM::User::Client;
use List::UtilsBy qw(sort_by);

use constant {
    OFFERINGS_NAMESPACE => 'OFFERINGS',
};

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

    $contracts_for->{available}     = _localize_contracts($contracts_for->{available});
    $contracts_for->{non_available} = _localize_contracts($contracts_for->{non_available});

    return $contracts_for;
};

rpc contracts_for_company => sub {
    my $params   = shift;
    my $language = $params->{language} // 'EN';

    my $args                 = _extract_params($params);
    my $app_id               = $args->{app_id};
    my $app_name             = $args->{brands}->get_app($app_id)->offerings;
    my $country_code         = $args->{country_code};
    my $landing_company_name = $args->{landing_company_name} // 'virtual';
    my $endpoint             = 'contracts_for_company';

    my $redis_key = join('_', $endpoint, $landing_company_name, $app_name, $country_code, $language);

    if (my $cache_hit = _get_cache($redis_key)) {
        return $cache_hit;
    }

    my $offerings     = get_all_contracts($args);
    my $all_contracts = decorate_brief($offerings);

    $all_contracts->{available} = _localize_contracts($all_contracts->{available});

    _set_cache($redis_key, $all_contracts);

    return $all_contracts;
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

=head2 _localize_contracts($contracts)

Localize C<contract_category_display> and C<contract display>

=over 4

=item C<$contracts> - arrayref of list of contracts

=back

=cut

sub _localize_contracts {
    my $contracts = shift;

    foreach my $c (@$contracts) {
        foreach my $attr (qw(contract_category_display contract_display)) {
            $c->{$attr} = localize($c->{$attr}) if $c->{$attr};
        }
    }

    return $contracts;
}

=head2 _get_cache($redis_key)

Get cache from redis-replicated if key exists.
Otherwise, return undef.

=over 4

=item C<$redis_key> - string

=back

=cut

sub _get_cache {
    my $redis_key = shift;

    my $value = BOM::Config::Chronicle::get_chronicle_reader()->get(OFFERINGS_NAMESPACE, $redis_key);

    return $value;
}

=head2 _set_cache($redis_key, $value, $cache_time)

Cache C<$value> in redis-replicated for a period of C<$cache_time>.

=over 4

=item C<$redis_key> - string

=item C<$value> - string, data that needs to be cached

=item C<$cache_time> - number, cache period in seconds. Default to 1 day.

=back

=cut

sub _set_cache {
    my ($redis_key, $value, $cache_time) = @_;
    $cache_time = $cache_time // 86400;

    # Set category, name, value, recording_date, archive, suppress_pub, cache time
    BOM::Config::Chronicle::get_chronicle_writer()->set(OFFERINGS_NAMESPACE, $redis_key, $value, Date::Utility->new(), 0, 0, $cache_time);

    return;
}

1;
