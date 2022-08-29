#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
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
use Digest::MD5  qw(md5_hex);
use Text::Trim   qw(trim);
use LandingCompany::Registry;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Log::Any                          qw($log);
use BOM::Backoffice::MultiplierRiskManagementTool;

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
        my $symbol            = $r->param('symbol')          // die 'symbol is undef';
        my $landing_company   = $r->param('landing_company') // die 'landing_company is undef';
        my $multiplier_config = {
            commission                  => $r->param('commission'),
            multiplier_range            => decode_json_utf8($r->param('multiplier_range')),
            cancellation_commission     => $r->param('cancellation_commission'),
            cancellation_duration_range => decode_json_utf8($r->param('cancellation_duration_range')),
            stop_out_level              => decode_json_utf8($r->param('stop_out_level')),
            expiry                      => $r->param('expiry'),
        };
        my $redis_key = join('::', 'multiplier_config', $landing_company, $symbol);
        $qc->save_config($redis_key, $multiplier_config);
        send_trading_ops_email("Multiplier risk management tool: updated $symbol configuration", $multiplier_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeMultiplierConfig", $multiplier_config);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
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

        send_trading_ops_email(
            "Multiplier risk management tool: updated affiliate commission",
            {
                financial     => $financial,
                non_financial => $non_financial
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAffiliateMultiplierCommission",
            'financial : '
                . $financial
                . ', non-financial :
            ' . $non_financial
        );

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_user_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $client_limits        = $custom_volume_limits->{clients} // {};
    my $offerings =
        LandingCompany::Registry->by_name('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config('buy', 1))
        ;    # 1 - exclude disable
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

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

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

        send_trading_ops_email("Multiplier risk management tool: updated client limit ($loginid)", $limit);
        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
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

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        die "limit not found" unless $client_limits->{$user_id}{$uniq_key};
        my $limit = delete $client_limits->{$user_id}{$uniq_key};

        $custom_volume_limits->{clients} = $client_limits;
        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        send_trading_ops_email("Multiplier risk management tool: deleted client limit ($loginid)", $limit);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
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

        my $limit;
        if ($market) {
            $limit = $market_limits->{$market} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        } elsif ($symbol) {
            $limit = $symbol_limits->{$symbol} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        }
        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        send_trading_ops_email("Multiplier risk management tool: updated custom volume limit",
            {$limit->%*, $market ? 'market' : 'symbol' => $market || $symbol});
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
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

        my $limit;
        if    ($market) { $limit = delete $market_limits->{$market}; }
        elsif ($symbol) { $limit = delete $symbol_limits->{$symbol}; }
        else            { die "market and symbol can not be both empty"; }

        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        send_trading_ops_email("Multiplier risk management tool: deleted custom volume limit",
            {$limit->%*, $market ? 'market' : 'symbol' => $market || $symbol});
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
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
        min_multiplier        => $r->param('min_multiplier')        || undef,
        max_multiplier        => $r->param('max_multiplier')        || undef,
        commission_adjustment => $r->param('commission_adjustment') || undef,
        dc_commission         => $r->param('dc_commission')         || undef,
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
        send_trading_ops_email("Multiplier risk management tool: updated custom multiplier commission", $args,);
        return $args;
    } catch ($e) {
        return {error => 'ERR: ' . $e};
    }
}

if ($r->param('delete_multiplier_custom_commission')) {
    my $name = $r->param('name');

    my $qc = BOM::Config::QuantsConfig->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        recorded_date    => Date::Utility->new,
    );

    my $deleted;
    try {
        $deleted = $qc->delete_config('custom_multiplier_commission', $name);
        print encode_json_utf8({success => $name});
    } catch ($e) {
        print encode_json_utf8({error => 'ERR: ' . $e});
    }

    if ($deleted) {
        if ($deleted->{start_time}) {
            $deleted->{start_time} = Date::Utility->new($deleted->{start_time})->datetime;
        }
        if ($deleted->{end_time}) {
            $deleted->{end_time} = Date::Utility->new($deleted->{end_time})->datetime;
        }
        send_trading_ops_email("Multiplier risk management tool: deleted custom multiplier commission", $deleted,);
    }
}

if ($r->param('save_dc_config')) {
    my $underlying_symbol = $r->param('underlying_symbol');
    my $landing_companies = $r->param('landing_company');
    my $dc_types          = $r->param('dc_types');
    my $start_date_limit  = $r->param('start_date_limit');
    my $start_time_limit  = $r->param('start_time_limit');
    my $end_date_limit    = $r->param('end_date_limit');
    my $end_time_limit    = $r->param('end_time_limit');
    my $dc_comment        = $r->param('dc_comment');

    my $args = {
        underlying_symbol => $underlying_symbol,
        landing_companies => $landing_companies,
        dc_types          => $dc_types,
        start_date_limit  => $start_date_limit,
        start_time_limit  => $start_time_limit,
        end_date_limit    => $end_date_limit,
        end_time_limit    => $end_time_limit,
        dc_comment        => $dc_comment,
    };

    my $validated_dc_arg = BOM::Backoffice::MultiplierRiskManagementTool::prepare_dc_args_for_create($args);
    if (ref $validated_dc_arg eq 'HASH' && defined $validated_dc_arg->{error}) {
        return print encode_json_utf8({error => $validated_dc_arg->{error}});
    }

    my @landing_companies_multiple = split(',', $landing_companies);
    my ($output, @errors, @items);

    foreach my $dc_arg ($validated_dc_arg->@*) {
        foreach my $landing_company (@landing_companies_multiple) {
            my $key  = "deal_cancellation";
            my $name = $dc_arg->{underlying_symbol} . "_" . $landing_company;
            $dc_arg->{id}                = $name;
            $dc_arg->{landing_companies} = $landing_company;

            my $result = BOM::Backoffice::MultiplierRiskManagementTool::save_deal_cancellation($key, $name, $dc_arg);

            if ($result->{success} == 1) {
                $output = {success => 1};
                push @items, {%{$dc_arg}{qw/id landing_companies underlying_symbol dc_types start_datetime_limit end_datetime_limit dc_comment/}};
            } else {
                push @errors, $result->{error};
                my $error = join ', ', @errors;
                $output = {error => $error};
                print encode_json_utf8($output);

                return;
            }
        }
    }

    $output->{items} = \@items;

    print encode_json_utf8($output);
}

if ($r->param('destroy_dc_config')) {
    my $dc_id = $r->param('dc_id');
    my $key   = "deal_cancellation";

    print encode_json_utf8(BOM::Backoffice::MultiplierRiskManagementTool::destroy_deal_cancellation($key, $dc_id));
}

if ($r->param('update_dc_config')) {
    my $dc_id = $r->param('dc_id');
    my $key   = "deal_cancellation";

    if (   $r->param('start_datetime_limit')
        && $r->param('start_datetime_limit') !~ /^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}$/
        && $r->param('start_datetime_limit') !~ /^\d{4}-\d{2}-\d{2}$/
        && $r->param('start_datetime_limit') !~ /^\d{2}:\d{2}:\d{2}$/)
    {
        print encode_json_utf8({error => "Start datetime is not in correct format."});
        return;
    }

    if (   $r->param('end_datetime_limit')
        && $r->param('end_datetime_limit') !~ /^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}$/
        && $r->param('end_datetime_limit') !~ /^\d{4}-\d{2}-\d{2}$/
        && $r->param('end_datetime_limit') !~ /^\d{2}:\d{2}:\d{2}$/)
    {
        print encode_json_utf8({error => "End datetime is not in correct format."});
        return;
    }

    my $start_date_limit;
    my $start_time_limit;
    my $end_date_limit;
    my $end_time_limit;

    # Parsing the date and time depending on the format of datetime fields.
    ($start_date_limit, $start_time_limit) = $r->param('start_datetime_limit') =~ /^(\d{4}-\d{2}-\d{2})\s(\d{2}:\d{2}:\d{2})$/;
    ($end_date_limit,   $end_time_limit)   = $r->param('end_datetime_limit')   =~ /^(\d{4}-\d{2}-\d{2})\s(\d{2}:\d{2}:\d{2})$/;

    $start_date_limit = $r->param('start_datetime_limit') if $r->param('start_datetime_limit') =~ /^\d{4}-\d{2}-\d{2}$/;
    $start_time_limit = $r->param('start_datetime_limit') if $r->param('start_datetime_limit') =~ /^\d{2}:\d{2}:\d{2}$/;

    $end_date_limit = $r->param('end_datetime_limit') if $r->param('end_datetime_limit') =~ /^\d{4}-\d{2}-\d{2}$/;
    $end_time_limit = $r->param('end_datetime_limit') if $r->param('end_datetime_limit') =~ /^\d{2}:\d{2}:\d{2}$/;

    my $new_config = {
        landing_companies => $r->param('landing_companies'),
        underlying_symbol => $r->param('underlying_symbol'),
        dc_types          => $r->param('dc_types'),
        start_date_limit  => $start_date_limit,
        start_time_limit  => $start_time_limit,
        end_date_limit    => $end_date_limit,
        end_time_limit    => $end_time_limit,
        dc_comment        => $r->param('dc_comment'),
    };

    my $validated_args = BOM::Backoffice::MultiplierRiskManagementTool::validate_deal_cancellation_args($new_config);

    if ($validated_args->{error}) {
        print encode_json_utf8($validated_args);
        return;
    }

    print encode_json_utf8(BOM::Backoffice::MultiplierRiskManagementTool::update_deal_cancellation($key, $dc_id, $validated_args));
}

if ($r->param('fetch_dc_config')) {
    my $reader     = BOM::Config::Chronicle::get_chronicle_reader();
    my $dc_configs = $reader->get("quants_config", "deal_cancellation");
    my %lc_grouped_dc_configs;

    foreach my $id (sort keys $dc_configs->%*) {
        push @{$lc_grouped_dc_configs{uc($dc_configs->{$id}->{landing_companies})}}, $dc_configs->{$id};
    }

    print encode_json_utf8(\%lc_grouped_dc_configs);
}
