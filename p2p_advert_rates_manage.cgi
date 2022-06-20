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
use List::Util qw(any all none);
use Scalar::Util qw(looks_like_number);
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;

use constant ACTIVATION_KEY => 'P2P::AD_ACTIVATION';

my $cgi = CGI->new;

PrintContentType();

code_exit_BO('<p class="error"><b>Both IT and Quants permissions are required to access this page</b></p>')
    unless BOM::Backoffice::Auth0::has_authorisation(['Quants']) && BOM::Backoffice::Auth0::has_authorisation(['IT']);

BrokerPresentation('P2P ADVERT RATES MANAGEMENT');

my $redis         = BOM::Config::Redis->redis_p2p_write;
my $app_config    = BOM::Config::Runtime->instance->app_config();
my $ad_config     = decode_json_utf8($app_config->payments->p2p->country_advert_config);
my $p2p_countries = BOM::Config::P2P::available_countries();
my $error         = "";

if (request()->http_method eq 'POST' and request()->params->{save}) {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    } else {
        my $data    = request()->params;
        my $country = $data->{country};

        my %defaults = (
            float_ads        => 'disabled',
            fixed_ads        => 'enabled',
            deactivate_fixed => ''
        );

        # It is not possible to set both floating and fixed rates as enabled or disabled or list_only
        # Basically we should always allow exactly one type of ad to be created
        unless ($data->{float_ads} eq 'enabled' xor $data->{fixed_ads} eq 'enabled') {

            if (all { $data->{$_} eq 'enabled' } qw/float_ads fixed_ads/) {
                $error = 'It is not possible to set both floating and fixed rates as enabled for any country';
            } else {
                $error = 'It is mandatory to enable one of floating and fixed rates as enabled for each country.';
            }
            $data->{$_} = $ad_config->{$country}{$_} // $defaults{$_} for qw(float_ads fixed_ads);
        }
        my %changes = map { $country . ':' . $_ => $data->{$_} }

            grep { $data->{$_} ne ($ad_config->{$country}->{$_} // $defaults{$_}) } qw(float_ads fixed_ads deactivate_fixed);

        $ad_config->{$country}{$_} = $data->{$_} for qw(float_ads fixed_ads deactivate_fixed);
        looks_like_number($data->{max_rate_range})
            ? $ad_config->{$country}{max_rate_range} = $data->{max_rate_range}
            : delete $ad_config->{$country}{max_rate_range};
        delete $ad_config->{$country}->@{qw(manual_quote manual_quote_epoch manual_quote_staff)} if $data->{remove_manual_quote};
        if (looks_like_number($data->{manual_quote})) {
            $ad_config->{$country}{manual_quote}       = $data->{manual_quote};
            $ad_config->{$country}{manual_quote_epoch} = time;
            $ad_config->{$country}{manual_quote_staff} = BOM::Backoffice::Auth0::get_staffname();
        }
        unless ($error) {
            code_exit_BO()
                unless BOM::DynamicSettings::save_settings({
                    'settings' => {
                        'payments.p2p.country_advert_config' => encode_json_utf8($ad_config),
                        revision                             => $data->{revision}
                    },
                    'settings_in_group' => ['payments.p2p.country_advert_config'],
                    'save'              => 'global',
                });
        }

        BOM::Config::Redis->redis_p2p_write->hset(ACTIVATION_KEY, %changes) if %changes;
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

my (@rows, @notices);
my $next_cron = Date::Utility->new->truncate_to_day->plus_time_interval('2h30m');
my $now       = Date::Utility->new;
$next_cron = $next_cron->plus_time_interval('24h') if $now->seconds_after_midnight > (2.5 * 60 * 60);
my %activation = $redis->hgetall(ACTIVATION_KEY)->@*;

for my $country (sort keys %$p2p_countries) {
    my $row = $ad_config->{$country};
    $row->{code} = $country;
    $row->{name} = $p2p_countries->{$country};
    $row->{fixed_ads} //= 'enabled';
    $row->{float_ads} //= 'disabled';
    $row->{manual_quote_age}  = $age_format->($row->{manual_quote_epoch})                if $row->{manual_quote_epoch};
    $row->{manual_quote_time} = Date::Utility->new($row->{manual_quote_epoch})->datetime if $row->{manual_quote_epoch};

    if ($row->{deactivate_fixed}) {
        my $date = Date::Utility->new($row->{deactivate_fixed});
        $row->{deactivate_fixed} = $date->date;
        if ($row->{fixed_ads} ne 'disabled' and ($activation{"$country:fixed_ads"} // '') ne 'disabled') {
            if ($next_cron->days_between($date) == 0) {
                push @notices,
                    "Fixed rate ads for $row->{name} will be deactivated because of the set date, and all users who have active ads will be emailed.";
            }
            if ($activation{"$country:deactivate_fixed"} and $date->is_after($now)) {
                push @notices,
                    "Users with active fixed rate ads in $row->{name} will be emailed that fixed rate ads are being disabled on " . $date->date;
            }
        }
    }

    if (my $currency = BOM::Config::CurrencyConfig::local_currency_for_country($country)) {
        $row->{currency} = $currency;
        if (my $quote = ExchangeRates::CurrencyConverter::usd_rate($currency)) {
            my $dt = Date::Utility->new($quote->{epoch});
            $row->{quote}      = $quote->{quote};
            $row->{p2p_quote}  = 1 / $quote->{quote};
            $row->{quote_age}  = $age_format->($quote->{epoch});
            $row->{quote_time} = $dt->datetime;
            $row->{old_quote}  = 1 if $dt->is_before(Date::Utility->new->minus_time_interval('24h'));
        }
    }
    push @rows, $row;

    push @notices, "Fixed rate ads for $row->{name} will be deactivated and all users who have active fixed rate ads will be emailed."
        if ($activation{"$country:fixed_ads"} // '') eq 'disabled';

    push @notices, "Float rate ads for $row->{name} will be deactivated and all users who have active float rate ads will be emailed."
        if ($activation{"$country:float_ads"} // '') eq 'disabled';
}

BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_advert_rates_manage.tt',
    {
        rows      => [sort { $a->{name} cmp $b->{name} } @rows],
        revision  => $app_config->global_revision(),
        next_cron => $next_cron->datetime,
        notices   => \@notices,
        error     => $error,
    });

code_exit_BO();
