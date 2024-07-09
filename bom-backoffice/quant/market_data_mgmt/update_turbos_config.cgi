#!/etc/rmg/bin/perl

package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Log::Any                          qw($log);
use YAML::XS                          qw(LoadFile);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();

my $qc = BOM::Config::QuantsConfig->new(
    contract_category => 'turbos',
    recorded_date     => Date::Utility->new,
    chronicle_writer  => BOM::Config::Chronicle::get_chronicle_writer(),
    chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
);

if ($r->param('save_turbos_risk_profile')) {
    my $output;
    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }

    try {
        my $currency   = $r->param('currency');
        my $risk_level = $r->param('risk_level');
        my $amount     = $r->param('amount');

        die 'Amount must be a number' unless looks_like_number($amount);
        die 'Amount can not be negative' if $amount < 0;

        my $existing_risk_profile = $qc->get_max_stake_per_risk_profile($risk_level);

        if ($currency eq 'All') {
            foreach my $ccy (keys %{$existing_risk_profile}) {
                $existing_risk_profile->{$ccy} = $amount;
            }
        } else {
            $existing_risk_profile->{$currency} = $amount;
        }

        my $redis_key = join('::', 'turbos', 'max_stake_per_risk_profile', $risk_level);
        $qc->save_config($redis_key, $existing_risk_profile);

        send_trading_ops_email("Turbos risk management tool: updated risk profile", $existing_risk_profile);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeTurbosConfig", $existing_risk_profile);

        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_turbos_market_or_underlying_risk_profile')) {
    my $market_risk_profiles = $qc->get_risk_profile_per_market // {};
    my $symbol_risk_profiles = $qc->get_risk_profile_per_symbol // {};

    my $output;
    try {
        my $limit_defs   = BOM::Config::quants()->{risk_profile};
        my $risk_profile = $r->param('risk_profile');
        die "invalid risk_profile" unless $risk_profile and $limit_defs->{$risk_profile};

        my $market = trim($r->param('market'));
        my $symbol = trim($r->param('symbol'));

        my @existing_markets = Finance::Underlying::Market::Registry->instance->all_market_names;
        die "invalid market" if $market and none { $market eq $_ } @existing_markets;

        my @existing_underlyings = Finance::Underlying->symbols;
        die "invalid underlying" if $symbol and none { $symbol eq $_ } @existing_underlyings;

        die "market and symbol can not be both set"   if $market  && $symbol;
        die "market and symbol can not be both empty" if !$market && !$symbol;

        die "comma seperated markets are not allowed" if $market =~ /,/;
        die "comma seperated symbols are not allowed" if $symbol =~ /,/;

        if ($market) {
            $market_risk_profiles->{$market} = $risk_profile;
            my $redis_key = join('::', 'turbos', 'risk_profile_per_market');
            $qc->save_config($redis_key, $market_risk_profiles);
        } elsif ($symbol) {
            $symbol_risk_profiles->{$symbol} = $risk_profile;
            my $redis_key = join('::', 'turbos', 'risk_profile_per_symbol');
            $qc->save_config($redis_key, $symbol_risk_profiles);
        }

        my $res = $market ? $market_risk_profiles : $symbol_risk_profiles;
        send_trading_ops_email("Turbos risk management tool: updated risk profiles", $res);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeRiskProfiles", $res);

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }
    print encode_json_utf8($output);

}

if ($r->param('delete_turbos_market_or_underlying_risk_profile')) {
    my $market_risk_profiles = $qc->get_risk_profile_per_market // {};
    my $symbol_risk_profiles = $qc->get_risk_profile_per_symbol // {};

    my $output;
    try {
        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        if ($market) {
            delete $market_risk_profiles->{$market};
            my $redis_key = join('::', 'turbos', 'risk_profile_per_market');
            $qc->save_config($redis_key, $market_risk_profiles);
        } elsif ($symbol) {
            delete $symbol_risk_profiles->{$symbol};
            my $redis_key = join('::', 'turbos', 'risk_profile_per_symbol');
            $qc->save_config($redis_key, $market_risk_profiles);
        } else {
            die "market and symbol can not be both empty";
        }

        my $res = $market ? $market_risk_profiles : $symbol_risk_profiles;
        send_trading_ops_email("Turbos risk management tool: deleted custom risk profiles", $res);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeRiskProfiles", $res);

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_turbos_affiliate_commission')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $output;
    my $financial;
    my $non_financial;
    try {
        $financial     = $r->param('financial');
        $non_financial = $r->param('non_financial');

        die "Commission must be within the range [0,1)" if ($financial < 0 or $financial >= 1) or ($non_financial < 0 or $non_financial >= 1);

        $app_config->set({'quants.turbos.affiliate_commission.financial'     => $financial});
        $app_config->set({'quants.turbos.affiliate_commission.non_financial' => $non_financial});

        send_trading_ops_email(
            "Turbos risk management tool: updated affiliate commission",
            {
                financial     => $financial,
                non_financial => $non_financial
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAffiliateTurbosCommission",
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

if ($r->param('save_turbos_per_symbol_config')) {
    my $output;

    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }

    try {
        my $symbol                         = $r->param('symbol') // die 'symbol is undef';
        my $num_of_barriers                = $r->param('num_of_barriers');
        my $min_distance_from_spot         = $r->param('min_distance_from_spot');
        my $min_expected_spot_movement_t   = $r->param('min_expected_spot_movement_t');
        my $max_expected_spot_movement_t   = $r->param('max_expected_spot_movement_t');
        my $increment_percentage           = $r->param('increment_percentage');
        my $ticks_commission_up_tick       = $r->param('ticks_commission_up_tick');
        my $ticks_commission_up_intraday   = $r->param('ticks_commission_up_intraday');
        my $ticks_commission_up_daily      = $r->param('ticks_commission_up_daily');
        my $ticks_commission_down_tick     = $r->param('ticks_commission_down_tick');
        my $ticks_commission_down_intraday = $r->param('ticks_commission_down_intraday');
        my $ticks_commission_down_daily    = $r->param('ticks_commission_down_daily');
        my $max_multiplier                 = $r->param('max_multiplier');
        my $max_multiplier_stake           = decode_json_utf8($r->param('max_multiplier_stake'));
        my $min_multiplier                 = $r->param('min_multiplier');
        my $min_multiplier_stake           = decode_json_utf8($r->param('min_multiplier_stake'));
        my $max_open_position              = $r->param('max_open_position');
        my $landing_company                = 'common';

        die "Symbol is not defined" if $symbol eq '';
        die "Number of barriers must be a number"             unless looks_like_number($num_of_barriers);
        die "min distance from spot must be a number"         unless looks_like_number($min_distance_from_spot);
        die "Min expected spot movement must be a number"     unless looks_like_number($min_expected_spot_movement_t);
        die "Max expected spot movement must be a number"     unless looks_like_number($max_expected_spot_movement_t);
        die "Increment percentage must be a number"           unless looks_like_number($increment_percentage);
        die "ticks commission up tick must be a number"       unless looks_like_number($ticks_commission_up_tick);
        die "ticks commission up intraday must be a number"   unless looks_like_number($ticks_commission_up_intraday);
        die "ticks commission up daily must be a number"      unless looks_like_number($ticks_commission_up_daily);
        die "ticks commission up daily must be a number"      unless looks_like_number($ticks_commission_down_tick);
        die "ticks commission down intraday must be a number" unless looks_like_number($ticks_commission_down_intraday);
        die "ticks commission down daily must be a number"    unless looks_like_number($ticks_commission_down_daily);
        die "max multiplier must be a number"                 unless looks_like_number($max_multiplier);
        die "min multiplier must be a number"                 unless looks_like_number($min_multiplier);
        die "max open position must be a number"              unless looks_like_number($max_open_position);

        # This block of code will be removed once we remove barrier options from turbos as it will no longer needed
        for my $currency (keys %$min_multiplier_stake) {
            my $min_multiplier_stake_for_currency = $min_multiplier_stake->{$currency};
            my $max_multiplier_stake_for_currency = $max_multiplier_stake->{$currency};
            die "min_multiplier * min_multiplier_stake($currency) can't be greater than max_multiplier * max_multiplier_stake($currency)"
                if $min_multiplier * $min_multiplier_stake_for_currency > $max_multiplier * $max_multiplier_stake_for_currency;
        }

        my $per_symbol_config = {
            num_of_barriers                => $num_of_barriers,
            min_distance_from_spot         => $min_distance_from_spot,
            min_expected_spot_movement_t   => $min_expected_spot_movement_t,
            max_expected_spot_movement_t   => $max_expected_spot_movement_t,
            increment_percentage           => $increment_percentage,
            ticks_commission_up_tick       => $ticks_commission_up_tick,
            ticks_commission_up_intraday   => $ticks_commission_up_intraday,
            ticks_commission_up_daily      => $ticks_commission_up_daily,
            ticks_commission_down_tick     => $ticks_commission_down_tick,
            ticks_commission_down_intraday => $ticks_commission_down_intraday,
            ticks_commission_down_daily    => $ticks_commission_down_daily,
            max_multiplier                 => $max_multiplier,
            max_multiplier_stake           => $max_multiplier_stake,
            min_multiplier                 => $min_multiplier,
            min_multiplier_stake           => $min_multiplier_stake,
            max_open_position              => $max_open_position,
        };

        my $redis_key = join('::', 'turbos', 'per_symbol', $landing_company, $symbol);
        $qc->save_config($redis_key, $per_symbol_config);
        send_trading_ops_email("Turbos risk management tool: updated $symbol configuration", $per_symbol_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeTurbosConfig", $per_symbol_config);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_turbos_user_specific_limits')) {
    my $output;
    my $max_open_position;
    my $max_daily_pnl;
    my $loginid;
    try {
        $loginid           = $r->param('loginid');
        $max_open_position = $r->param('max_open_position');
        $max_daily_pnl     = $r->param('max_daily_pnl');

        die "max open positions must be a number" unless looks_like_number($max_open_position);
        die "max daily pnl must be a number"      unless looks_like_number($max_daily_pnl);
        die 'Max open positions must be bigger than 0' if $max_open_position <= 0;
        die 'Max daily pnl must be bigger than 0'      if $max_daily_pnl <= 0;

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

        die "invalid loginid " . $loginid unless $client;
        my $user_specific_limits = $qc->get_user_specific_limits    // {};
        my $client_limits        = $user_specific_limits->{clients} // {};

        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        my $limit = {
            loginid           => $loginid,
            max_open_position => $max_open_position,
            max_daily_pnl     => $max_daily_pnl,
        };

        $client_limits->{$user_id} = $limit;
        $user_specific_limits->{clients} = $client_limits;

        my $redis_key = join('::', 'turbos', 'user_specific_limits');
        $qc->save_config($redis_key, $user_specific_limits);

        send_trading_ops_email("Turbos risk management tool: updated user specific config",
            {"loginid: $loginid", "max open positions: $max_open_position", "max daily : $max_daily_pnl",});
        BOM::Backoffice::QuantsAuditLog::log(
            $staff, "ChangeTurbosPerClientConfig",
            "loginid : $loginid",
            "max open positions : $max_open_position",
            "max daily pnl : $max_daily_pnl",
        );

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_turbos_user_specific_limit')) {
    my $user_specific_limits = $qc->get_user_specific_limits;
    my $client_limits        = $user_specific_limits->{clients} // {};
    my $output;
    try {
        my $loginid = $r->param('loginid');

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        die "limit not found" unless $client_limits->{$user_id};
        my $limit = delete $client_limits->{$user_id};

        $user_specific_limits->{clients} = $client_limits;

        my $redis_key = join('::', 'turbos', 'user_specific_limits');
        $qc->save_config($redis_key, $user_specific_limits);

        send_trading_ops_email("Turbos risk management tool: deleted client limit ($loginid)", $limit);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $user_specific_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}
