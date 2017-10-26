package BOM::RPC::v3::Static;

use strict;
use warnings;

use Format::Util::Numbers;
use List::Util qw( min );

use Brands;
use LandingCompany::Registry;

use BOM::Platform::Runtime;
use BOM::Platform::Locale;
use BOM::Platform::Config;
use BOM::Platform::Context qw (request);
use BOM::RPC::v3::Utility;

sub residence_list {
    my $residence_countries_list;

    my $countries_instance = Brands->new(name => request()->brand)->countries_instance;
    my $countries = $countries_instance->countries;
    foreach my $country_selection (
        sort { $a->{translated_name} cmp $b->{translated_name} }
        map { +{code => $_, translated_name => $countries->localized_code2country($_, request()->language)} } $countries->all_country_codes
        )
    {
        my $country_code = $country_selection->{code};
        next if $country_code eq '';
        my $country_name = $country_selection->{translated_name};
        my $phone_idd    = $countries->idd_from_code($country_code);

        my $option = {
            value => $country_code,
            text  => $country_name,
            $phone_idd ? (phone_idd => $phone_idd) : ()};

        # to be removed later - JP
        if ($countries_instance->restricted_country($country_code) or $country_code eq 'jp') {
            $option->{disabled} = 'DISABLED';
        } elsif (request()->country_code eq $country_code) {
            $option->{selected} = 'selected';
        }
        push @$residence_countries_list, $option;
    }

    return $residence_countries_list;
}

sub states_list {
    my $params = shift;

    my $states = BOM::Platform::Locale::get_state_option($params->{args}->{states_list});
    $states = [grep { $_->{value} ne '' } @$states];
    return $states;
}

sub _currencies_config {
    my $amt_precision = Format::Util::Numbers::get_precision_config()->{price};
    my $bet_limits    = BOM::Platform::Config::quants->{bet_limits};
    # As a stake_default (amount, which will be pre-populated for this currency on our website,
    # if there were no amount entered by client), we get max out of two minimal possible stakes.
    # Logic is copied from _build_staking_limits
    my %currencies_config = map {
        $_ => {
            fractional_digits => $amt_precision->{$_},
            type              => LandingCompany::Registry::get_currency_type($_),
            stake_default     => min($bet_limits->{min_payout}->{volidx}->{$_}, $bet_limits->{min_payout}->{default}->{$_}) / 2,
            }
        }
        keys LandingCompany::Registry::get('costarica')->legal_allowed_currencies;
    return \%currencies_config;
}

sub website_status {
    my $params = shift;

    my $app_config = BOM::Platform::Runtime->instance->app_config;
    return {
        terms_conditions_version => $app_config->cgi->terms_conditions_version,
        api_call_limits          => BOM::RPC::v3::Utility::site_limits,
        clients_country          => $params->{country_code},
        supported_languages      => $app_config->cgi->supported_languages,
        currencies_config        => _currencies_config(),
        ico_status               => (
            $app_config->system->suspend->is_auction_ended
                or not $app_config->system->suspend->is_auction_started
        ) ? 'closed' : 'open',
    };
}

1;
