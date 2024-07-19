#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::Sysinit      ();
BOM::Backoffice::Sysinit::init();

use BOM::Backoffice::Utility qw(master_live_server_error);
use BOM::Backoffice::Auth;
use BOM::DynamicSettings;
use BOM::Config::Runtime;
use BOM::Config::P2P;
use BOM::Config::CurrencyConfig;
use BOM::User::Utility;
use ExchangeRates::CurrencyConverter;
use List::Util      qw(any all none);
use Scalar::Util    qw(looks_like_number);
use Array::Utils    qw(intersect);
use JSON::MaybeUTF8 qw(:v1);
use Date::Utility;
use Math::BigFloat;
use BOM::Platform::Event::Emitter;

use constant ACTIVATION_KEY => 'P2P::AD_ACTIVATION';

my $cgi = CGI->new;

PrintContentType();

BrokerPresentation('P2P ADVERT RATES MANAGEMENT');

my %params          = request()->params->%*;
my $redis           = BOM::Config::Redis->redis_p2p_write;
my $app_config      = BOM::Config::Runtime->instance->app_config();
my $ad_config       = decode_json_utf8($app_config->payments->p2p->country_advert_config);
my $currency_config = decode_json_utf8($app_config->payments->p2p->currency_config);
my %p2p_countries   = BOM::Config::P2P::available_countries()->%*;
my %currencies      = %BOM::Config::CurrencyConfig::ALL_CURRENCIES;
my @p2p_countries   = keys %p2p_countries;
my %output;

if (request()->http_method eq 'POST') {
    if (not(grep { $_ eq 'binary_role_master_server' } @{BOM::Config::node()->{node}->{roles}})) {
        code_exit_BO('<p class="error"><b>' . master_live_server_error() . '</b></p>');
    }
}

if (my $currency = $params{save}) {
    my $currency_settings_changed = 0;
    my (@country_ads_changed, @updated_countries) = ();

    if ($params{remove_manual_quote}) {
        delete $currency_config->{$currency}->@{qw(manual_quote manual_quote_epoch manual_quote_staff)};
        $currency_settings_changed = 1;
    } elsif (looks_like_number($params{manual_quote})) {
        $currency_config->{$currency}->{manual_quote}       = $params{manual_quote};
        $currency_config->{$currency}->{manual_quote_epoch} = time;
        $currency_config->{$currency}->{manual_quote_staff} = BOM::Backoffice::Auth::get_staffname();
        $currency_settings_changed                          = 1;
    }

    if (looks_like_number($params{max_rate_range})) {
        $currency_config->{$currency}{max_rate_range} = $params{max_rate_range};
        $currency_settings_changed = 1;
    } else {
        $currency_settings_changed = 1 if delete $currency_config->{$currency}{max_rate_range};
    }

    my ($settings_saved_flag, @updated_keys) = BOM::DynamicSettings::save_settings({
            'settings' => {
                'payments.p2p.currency_config' => encode_json_utf8($currency_config),
                revision                       => $params{revision}
            },
            'settings_in_group' => ['payments.p2p.currency_config'],
            'save'              => 'global',
        });

    code_exit_BO() unless $settings_saved_flag;
    push @updated_countries, grep { $p2p_countries{$_} } $currencies{$currency}->{countries}->@*
        if $currency_settings_changed
        && any { $_ eq "payments.p2p.currency_config" } @updated_keys;

    my %country_updates;
    for my $param (keys %params) {
        for my $setting (qw (float_ads fixed_ads deactivate_fixed)) {
            if (my ($country) = $param =~ /(\w{2})_$setting/) {
                $country_updates{$country}{$setting} = $params{$param};
            }
        }
    }

    my %defaults = (
        float_ads        => 'disabled',
        fixed_ads        => 'enabled',
        deactivate_fixed => ''
    );

    for my $country (keys %country_updates) {
        my %update = $country_updates{$country}->%*;
        # It is not possible to set both floating and fixed rates as enabled or disabled or list_only
        # Basically we should always allow exactly one type of ad to be created
        unless ($update{float_ads} eq 'enabled' xor $update{fixed_ads} eq 'enabled') {
            if (all { $update{$_} eq 'enabled' } qw/float_ads fixed_ads/) {
                push $output{errors}->@*, "Invalid settting for $p2p_countries{$country}: fixed and floating rates cannot both be enabled.";
            } else {
                push $output{errors}->@*, "Invalid settting for $p2p_countries{$country}: fixed and floating rates cannot both be disabled.";
            }
            next;
        }

        my %changes = map { $country . ':' . $_ => $update{$_} }
            grep { $update{$_} ne ($ad_config->{$country}{$_} // $defaults{$_}) } qw(float_ads fixed_ads deactivate_fixed);

        if (%changes) {
            BOM::Config::Redis->redis_p2p_write->hset(ACTIVATION_KEY, %changes);
            push @country_ads_changed, $country;
        }

        $ad_config->{$country}{$_} = $update{$_} for qw(float_ads fixed_ads deactivate_fixed);

    }

    ($settings_saved_flag, @updated_keys) = BOM::DynamicSettings::save_settings({
            'settings' => {
                'payments.p2p.country_advert_config' => encode_json_utf8($ad_config),
                revision                             => $app_config->global_revision(),
            },
            'settings_in_group' => ['payments.p2p.country_advert_config'],
            'save'              => 'global',
        });

    code_exit_BO() unless $settings_saved_flag;
    push @updated_countries, @country_ads_changed if @country_ads_changed && any { $_ eq "payments.p2p.country_advert_config" } @updated_keys;

    BOM::Platform::Event::Emitter::emit(
        p2p_settings_updated => {
            affected_countries => \@updated_countries,
            force_update       => 1
        }) if @updated_countries && !($currencies{$currency}->{is_legacy});
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

my $next_cron = Date::Utility->new->truncate_to_day->plus_time_interval('2h30m');
my $now       = Date::Utility->new;
$next_cron = $next_cron->plus_time_interval('24h') if $now->seconds_after_midnight > (2.5 * 60 * 60);
my %activation = $redis->hgetall(ACTIVATION_KEY)->@*;

for my $country (keys %p2p_countries) {
    my $country_config = $ad_config->{$country} //= {};

    $country_config->{code} = $country;
    $country_config->{name} = $p2p_countries{$country};
    $country_config->{fixed_ads} //= 'enabled';
    $country_config->{float_ads} //= 'disabled';

    if ($country_config->{deactivate_fixed}) {
        my $date = Date::Utility->new($country_config->{deactivate_fixed});
        $country_config->{deactivate_fixed} = $date->date;

        if ($country_config->{fixed_ads} ne 'disabled' and ($activation{"$country:fixed_ads"} // '') ne 'disabled') {
            if ($next_cron->days_between($date) == 0) {
                push $output{cron_notices}->@*,
                    "Fixed rate ads for $p2p_countries{$country} will be deactivated because of the set date, and all users who have active ads will be emailed.";
            }
            if ($activation{"$country:deactivate_fixed"} and $date->is_after($now)) {
                push $output{cron_notices}->@*,
                    "Users with active fixed rate ads in $p2p_countries{$country} will be emailed that fixed rate ads are being disabled on "
                    . $date->date;
            }
        }
    }

    push $output{cron_notices}->@*,
        "Fixed rate ads for $p2p_countries{$country} will be deactivated and all users who have active fixed rate ads will be emailed."
        if ($activation{"$country:fixed_ads"} // '') eq 'disabled';

    push $output{cron_notices}->@*,
        "Float rate ads for $p2p_countries{$country} will be deactivated and all users who have active float rate ads will be emailed."
        if ($activation{"$country:float_ads"} // '') eq 'disabled';
}

for my $currency (sort keys %currencies) {
    my @countries = grep { $p2p_countries{$_} } $currencies{$currency}->{countries}->@*;
    next unless @countries;

    my $currency_item;
    $currency_item->{symbol}         = $currency;
    $currency_item->{name}           = $currencies{$currency}->{name};
    $currency_item->{max_rate_range} = $currency_config->{$currency}->{max_rate_range};

    if (my $quote = ExchangeRates::CurrencyConverter::usd_rate($currency)) {
        my $dt = Date::Utility->new($quote->{epoch});
        $currency_item->{feed_quote}      = Math::BigFloat->new($quote->{quote});
        $currency_item->{feed_quote_age}  = $age_format->($quote->{epoch});
        $currency_item->{feed_quote_time} = $dt->datetime;
        $currency_item->{old_quote}       = 1 if $dt->is_before(Date::Utility->new->minus_time_interval('24h'));
    }

    $currency_item->{manual_quote}       = $currency_config->{$currency}{manual_quote};
    $currency_item->{manual_quote_staff} = $currency_config->{$currency}{manual_quote_staff};
    if (my $epoch = $currency_config->{$currency}{manual_quote_epoch}) {
        $currency_item->{manual_quote_age}  = $age_format->($epoch);
        $currency_item->{manual_quote_time} = Date::Utility->new($epoch)->datetime;
    }

    my $p2p_quote = BOM::User::Utility::p2p_exchange_rate($currency);
    $currency_item->{p2p_quote}           = $p2p_quote->{quote};
    $currency_item->{p2p_quote_formatted} = BOM::User::Utility::p2p_rate_rounding($p2p_quote->{quote});
    $currency_item->{p2p_quote_source}    = $p2p_quote->{source};

    for my $country (sort { $p2p_countries{$a} cmp $p2p_countries{$b} } @countries) {
        push $currency_item->{countries}->@*, $ad_config->{$country};
    }

    if ($currencies{$currency}->{is_legacy}) {
        push $output{legacy_currencies}->@*, $currency_item;
    } else {
        push $output{active_currencies}->@*, $currency_item;
    }
}
BOM::Backoffice::Request::template()->process(
    'backoffice/p2p/p2p_advert_rates_manage.tt',
    {
        %output,
        revision  => $app_config->global_revision(),
        next_cron => $next_cron->datetime,
    });

code_exit_BO();
