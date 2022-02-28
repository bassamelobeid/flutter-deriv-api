#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::Sysinit ();
BOM::Backoffice::Sysinit::init();

use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::Backoffice::Auth0;
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use BOM::Config::P2P;
use BOM::Config::CurrencyConfig;
use ExchangeRates::CurrencyConverter;
use List::Util qw(any);
use Scalar::Util qw(looks_like_number);
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;

my $cgi = CGI->new;

PrintContentType();

code_exit_BO('<p class="error"><b>Both IT and Quants permissions are required to access this page</b></p>')
    unless BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

BrokerPresentation('P2P FLOATING RATE ADVERT MANAGEMENT');

my $app_config    = BOM::Config::Runtime->instance->app_config();
my $ad_config     = decode_json_utf8($app_config->payments->p2p->country_advert_config);
my $p2p_countries = BOM::Config::P2P::available_countries();

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my $data = request()->params;
        $ad_config->{$data->{country}}{$_} = $data->{$_} for qw(float_ads fixed_ads deactivate_fixed);
        looks_like_number($data->{max_rate_range})
            ? $ad_config->{$data->{country}}{max_rate_range} = $data->{max_rate_range}
            : delete $ad_config->{$data->{country}}{max_rate_range};
        delete $ad_config->{$data->{country}}->@{qw(manual_quote manual_quote_epoch manual_quote_staff)} if $data->{remove_manual_quote};
        if (looks_like_number($data->{manual_quote})) {
            $ad_config->{$data->{country}}{manual_quote}       = $data->{manual_quote};
            $ad_config->{$data->{country}}{manual_quote_epoch} = time;
            $ad_config->{$data->{country}}{manual_quote_staff} = BOM::Backoffice::Auth0::get_staffname();
        }

        BOM::DynamicSettings::save_settings({
                'settings' => {
                    'payments.p2p.country_advert_config' => encode_json_utf8($ad_config),
                    revision                             => $data->{revision}
                },
                'settings_in_group' => ['payments.p2p.country_advert_config'],
                'save'              => 'global',
            });
    }
}

my $age_format = sub {
    my $epoch = shift;
    my $age   = time - $epoch;
    if ($age > 86400) {    # truncate to nearest hour when > 1 day
        $age = int($age / 3600) * 3600;
    } elsif ($age > 3600) {    # truncate to nearest minute when > 1 hour
        $age = int($age / 60) * 60;
    }
    return Time::Duration::Concise->new(interval => $age)->as_concise_string;
};

my @rows;
for my $country (keys %$p2p_countries) {
    my $row = $ad_config->{$country};
    $row->{code} = $country;
    $row->{name} = $p2p_countries->{$country};
    $row->{fixed_ads} //= 'enabled';
    $row->{manual_quote_age}  = $age_format->($row->{manual_quote_epoch})                if $row->{manual_quote_epoch};
    $row->{manual_quote_time} = Date::Utility->new($row->{manual_quote_epoch})->datetime if $row->{manual_quote_epoch};

    if (my $currency = BOM::Config::CurrencyConfig::local_currency_for_country($country)) {
        $row->{currency} = $currency;
        if (my $quote = ExchangeRates::CurrencyConverter::usd_rate($currency)) {
            $row->{quote}      = $quote->{quote};
            $row->{p2p_quote}  = 1 / $quote->{quote};
            $row->{quote_age}  = $age_format->($quote->{epoch});
            $row->{quote_time} = Date::Utility->new($quote->{epoch})->datetime,;
        }
    }
    push @rows, $row;
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_float_rate_ads_manage.tt',
    {
        rows     => [sort { $a->{name} cmp $b->{name} } @rows],
        revision => $app_config->global_revision(),
    });

code_exit_BO();
