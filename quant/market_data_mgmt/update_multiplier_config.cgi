#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8 qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CustomCommissionTool;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Config::QuantsConfig;
use BOM::Config::Chronicle;
use Date::Utility;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;
use Scalar::Util qw(looks_like_number);
use Digest::MD5 qw(md5_hex);
use Text::Trim qw(trim);
use LandingCompany::Registry;
use BOM::Config::Runtime;

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('save_multiplier_config')) {
    my $qc = BOM::Config::QuantsConfig->new(
        recorded_date    => Date::Utility->new,
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );
    my $output;
    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }
    try {
        my $symbol          = $r->param('symbol')          // die 'symbol is undef';
        my $landing_company = $r->param('landing_company') // die 'landing_company is undef';
        my $multiplier_config = {
            commission                  => $r->param('commission'),
            multiplier_range            => decode_json_utf8($r->param('multiplier_range')),
            cancellation_commission     => $r->param('cancellation_commission'),
            cancellation_duration_range => decode_json_utf8($r->param('cancellation_duration_range')),
            stop_out_level              => decode_json_utf8($r->param('stop_out_level')),
        };
        my $redis_key = join('::', 'multiplier_config', $landing_company, $symbol);
        $qc->save_config($redis_key, $multiplier_config);

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeMultiplierConfig", $multiplier_config);
        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_affiliate_commission')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $output;
    my $financial;
    my $non_financial;
    try {
        $financial     = $r->param('financial');
        $non_financial = $r->param('non_financial');

        die "Commission must be within the range [0,1)" if ($financial < 0 or $financial >= 1) or ($non_financial < 0 or $non_financial >= 1);

        $app_config->set({'quants.multiplier_affiliate_commission.financial'     => $financial});
        $app_config->set({'quants.multiplier_affiliate_commission.non_financial' => $non_financial});

        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAffiliateMultiplierCommission",
            'financial : '
                . $financial
                . ', non-financial :
            ' . $non_financial
        );

        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_user_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $client_limits        = $custom_volume_limits->{clients} // {};
    my $offerings =
        LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config('buy', 1));   # 1 - exclude disable
    my $output;
    try {
        my $loginid = $r->param('loginid') // die 'loginid is undef';
        die "loginid is required" if !$loginid;

        my $volume_limit = $r->param('volume_limit') // die 'volume_limit is undef';
        die "volume limit is required"     if !defined $volume_limit;
        die "volume limit must be numeric" if !looks_like_number($volume_limit);

        my $symbol = $r->param('symbol');
        for my $sym (split ',', $symbol) {
            die "symbol '$sym' is not valid" if $sym && !$offerings->query({
                contract_category => 'multiplier',
                underlying_symbol => $sym
            });
        }

        my $comment = $r->param('comment') // '';

        my $client = eval { BOM::User::Client->new({loginid => $loginid}) };
        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        my $limit = {
            loginid      => $loginid,
            volume_limit => $volume_limit
        };
        $limit->{symbol}  = $symbol  if $symbol;
        $limit->{comment} = $comment if $comment;

        my $uniq_key = substr(md5_hex($loginid . ($symbol // '')), 0, 16);
        $limit->{uniq_key} = $uniq_key;

        $client_limits->{$user_id}{$uniq_key} = $limit;
        $custom_volume_limits->{clients} = $client_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_multiplier_user_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $client_limits        = $custom_volume_limits->{clients} // {};
    my $output;
    try {
        my $loginid  = $r->param('loginid');
        my $uniq_key = $r->param('uniq_key');

        my $client = eval { BOM::User::Client->new({loginid => $loginid}) };
        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        die "limit not found" unless $client_limits->{$user_id}{$uniq_key};
        delete $client_limits->{$user_id}{$uniq_key};

        $custom_volume_limits->{clients} = $client_limits;
        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_market_or_underlying_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $market_limits        = $custom_volume_limits->{markets} // {};
    my $symbol_limits        = $custom_volume_limits->{symbols} // {};
    my $output;
    try {
        my $limit_defs   = BOM::Config::quants()->{risk_profile};
        my $risk_profile = $r->param('risk_profile');
        die "invalid risk_profile" unless $risk_profile and $limit_defs->{$risk_profile};

        my $market = trim($r->param('market'));
        my $symbol = trim($r->param('symbol'));

        my $max_volume_positions = $r->param('max_volume_positions');
        die "max_volume_positions is required"     if !$max_volume_positions;
        die "max_volume_positions must be numeric" if !looks_like_number($max_volume_positions);
        die "max_volume_positions is too large"    if $max_volume_positions > 10;

        die "market and symbol can not be both set"   if $market  && $symbol;
        die "market and symbol can not be both empty" if !$market && !$symbol;

        die "comma seperated markets are not allowed" if $market =~ /,/;
        die "comma seperated symbols are not allowed" if $symbol =~ /,/;

        if ($market) {
            $market_limits->{$market} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        } elsif ($symbol) {
            $symbol_limits->{$symbol} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        }
        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_multiplier_market_or_underlying_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $market_limits        = $custom_volume_limits->{markets} // {};
    my $symbol_limits        = $custom_volume_limits->{symbols} // {};
    my $output;
    try {
        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        if    ($market) { delete $market_limits->{$market}; }
        elsif ($symbol) { delete $symbol_limits->{$symbol}; }
        else            { die "market and symbol can not be both empty"; }

        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_custom_commission')) {

    my $args = {
        staff                 => $staff,
        name                  => $r->param('name'),
        currency_symbol       => $r->param('currency_symbol'),
        underlying_symbol     => $r->param('underlying_symbol'),
        start_time            => $r->param('start_time'),
        end_time              => $r->param('end_time'),
        min_multiplier        => $r->param('min_multiplier') || undef,
        max_multiplier        => $r->param('max_multiplier') || undef,
        commission_adjustment => $r->param('commission_adjustment') || undef,
        dc_commission         => $r->param('dc_commission') || undef,
    };

    print encode_json_utf8(_save_multiplier_custom_commission($args));
}

sub _save_multiplier_custom_commission {
    my $args = shift;
    my $now  = Date::Utility->new();

    my ($start, $end);

    my $identifier = $args->{name} || return {error => 'ERR: ' . 'name is required'};
    return {error => 'ERR: ' . 'name should only contain words and integers'} unless $identifier =~ /^([A-Za-z0-9]+ ?)*$/;

    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => $now,
    );

    my $existing_configs_arr = $qc->get_config('custom_multiplier_commission') // {};
    my %existing_configs     = map { $_->{name} => $_ } @{$existing_configs_arr};
    return {error => 'ERR: ' . 'Cannot use an identical name.'} if $existing_configs{$identifier};
    return {error => 'ERR: ' . 'start_time is required'} unless $args->{start_time};
    return {error => 'ERR: ' . 'end_time is required'}   unless $args->{end_time};

    my $error;
    try {
        $start = Date::Utility->new($args->{start_time});
        $end   = Date::Utility->new($args->{end_time});
        $error = {error => 'ERR: ' . "Start time and end time should not be in the past"} if $start->is_before($now) or $end->is_before($now);
    } catch {
        $error = {error => 'ERR: ' . "Invalid date format"} unless $start and $end;
    }

    return $error if defined $error and defined $error->{error};

    for my $time_name (qw(start_time end_time)) {
        $args->{$time_name} =~ s/^\s+|\s+$//g;
        try {
            $args->{$time_name} = Date::Utility->new($args->{$time_name})->epoch;
        } catch {
            return {error => 'ERR: ' . "Invalid $time_name format"};
        }
    }

    for my $key (qw(currency_symbol underlying_symbol)) {
        my @values = split ',', $args->{$key};
        $args->{$key} = \@values;
    }

    for (qw(commission_adjustment dc_commission min_multiplier max_multiplier)) {
        return {error => 'ERR: ' . "Min multiplier, Max multiplier, Commission adjustment or dc commission must be a number"}
            if defined $args->{$_} and not looks_like_number($args->{$_});
    }

    $existing_configs{$identifier} = $args;

    foreach my $name (keys %existing_configs) {
        delete $existing_configs{$name} if ($existing_configs{$name}->{end_time} < $now->epoch);
    }

    try {
        $qc->save_config('custom_multiplier_commission', \%existing_configs);
        $args->{start_time} = Date::Utility->new($args->{start_time})->datetime;
        $args->{end_time}   = Date::Utility->new($args->{end_time})->datetime;
        return $args;
    } catch {
        return {error => 'ERR: ' . $@};
    }
}

if ($r->param('delete_multiplier_custom_commission')) {
    my $name = $r->param('name');

    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );

    try {
        $qc->delete_config('custom_multiplier_commission', $name);
        print encode_json_utf8({success => $name});
    } catch {
        print encode_json_utf8({error => 'ERR: ' . $@});
    }
}
