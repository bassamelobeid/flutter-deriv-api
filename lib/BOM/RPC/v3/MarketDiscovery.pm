package BOM::RPC::v3::MarketDiscovery;

use strict;
use warnings;

use BOM::RPC::Registry '-dsl';

use BOM::User::Client;
use BOM::Platform::Context qw (localize request);
use List::UtilsBy qw(sort_by);
use BOM::Product::Offerings::TradingSymbol qw(get_symbols);

rpc active_symbols => sub {
    my $params = shift;

    my $landing_company_name = $params->{args}->{landing_company} // 'virtual';
    my $language             = $params->{language} || 'EN';
    my $token_details        = $params->{token_details};
    my $country_code         = $params->{country_code} // '';
    my $app_id               = $params->{valid_source} // $params->{source};

    if ($token_details and exists $token_details->{loginid}) {
        my $client = BOM::User::Client->new({
            loginid      => $token_details->{loginid},
            db_operation => 'replica'
        });

        $landing_company_name = $client->landing_company->short;
        $country_code         = $client->residence;
    }

    my $res = get_symbols({
        landing_company_name => $landing_company_name,
        country_code         => $country_code,
        app_id               => $app_id,
        brands               => request()->brand,
        type                 => $params->{args}->{active_symbols},
    });

    my @active_symbols =
        map {
        $_->{display_name}           = localize($_->{display_name});
        $_->{market_display_name}    = localize($_->{market_display_name});
        $_->{submarket_display_name} = localize($_->{submarket_display_name});
        $_
        } sort_by { $_->{display_name} =~ s{([0-9]+)}{sprintf "%-09.09d", $1}ger } $res->{symbols}->@*;

    return \@active_symbols;
};

1;
