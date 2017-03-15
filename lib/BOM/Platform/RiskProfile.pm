package BOM::Platform::RiskProfile;

use strict;
use warnings;
use JSON::RPC::Client;
use feature "state";

use BOM::Platform::Config;
use BOM::Platform::Runtime;
use Finance::Asset::Market::Registry;
use LandingCompany::Offerings qw(get_offerings_with_filter);

sub get_current_profile_definitions {
    my $client = shift;

    my ($currency, $landing_company);
    if ($client) {
        ($currency, $landing_company) = ($client->currency, $client->landing_company->short);
    } else {
        # set some defaults here
        ($currency, $landing_company) = ('USD', 'costarica');
    }

    my $config = BOM::Platform::Runtime->instance->get_offerings_config;
    my @markets =
        map { Finance::Asset::Market::Registry->get($_) } get_offerings_with_filter($config, 'market', {landing_company => $landing_company});
    my $limit_ref = BOM::Platform::Config::quants->{risk_profile};

    my %limits;
    foreach my $market (@markets) {
        my @submarket_list =
            grep { $_->risk_profile }
            map { Finance::Asset::SubMarket::Registry->get($_) } get_offerings_with_filter($config, 'submarket', {market => $market->name});
        if (@submarket_list) {
            my @list = map { {
                    name           => $_->display_name,
                    turnover_limit => $limit_ref->{$_->risk_profile}{turnover}{$currency},
                    payout_limit   => $limit_ref->{$_->risk_profile}{payout}{$currency},
                    profile_name   => $_->risk_profile
                }
            } @submarket_list;
            push @{$limits{$market->name}}, @list;
        } else {
            push @{$limits{$market->name}},
                +{
                name           => $market->display_name,
                turnover_limit => $limit_ref->{$market->risk_profile}{turnover}{$currency},
                payout_limit   => $limit_ref->{$market->risk_profile}{payout}{$currency},
                profile_name   => $market->risk_profile,
                };
        }
    }

    return \%limits;
}

1;
