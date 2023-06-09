#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
use Scalar::Util             qw(looks_like_number);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Log::Any                          qw($log);
use Digest::MD5                       qw(md5_hex);
use Data::Dump                        qw(pp);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('save_vanilla_affiliate_commission')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $output;
    my $financial;
    my $non_financial;
    try {
        $financial     = $r->param('financial');
        $non_financial = $r->param('non_financial');

        die "Commission must be within the range [0,1)" if ($financial < 0 or $financial >= 1) or ($non_financial < 0 or $non_financial >= 1);

        $app_config->set({'quants.vanilla.affiliate_commission.financial'     => $financial});
        $app_config->set({'quants.vanilla.affiliate_commission.non_financial' => $non_financial});

        send_trading_ops_email(
            "Vanilla risk management tool: updated affiliate commission",
            {
                financial     => $financial,
                non_financial => $non_financial
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAffiliateVanillaCommission",
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

if ($r->param('save_vanilla_user_specific_limits')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $output;
    my $max_open_position;
    my $max_daily_volume;
    my $max_daily_pnl;
    my $max_stake_per_trade;
    my $loginid;
    try {
        $loginid             = $r->param('loginid');
        $max_open_position   = $r->param('max_open_position');
        $max_daily_volume    = $r->param('max_daily_volume');
        $max_daily_pnl       = $r->param('max_daily_pnl');
        $max_stake_per_trade = $r->param('max_stake_per_trade');

        die 'Max open position must be bigger than 0'   if $max_open_position <= 0;
        die 'Max daily volume must be bigger than 0'    if $max_daily_volume <= 0;
        die 'Max daily pnl must be bigger than 0'       if $max_daily_pnl <= 0;
        die 'Max stake per trade must be bigger than 0' if $max_stake_per_trade <= 0;

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

        die "invalid loginid " . $loginid unless $client;

        my $user_specific_limits = decode_json_utf8($app_config->get('quants.vanilla.user_specific_limits'));
        my $client_limits        = $user_specific_limits->{clients} // {};

        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        my $limit = {
            loginid             => $loginid,
            max_open_position   => $max_open_position,
            max_daily_volume    => $max_daily_volume,
            max_daily_pnl       => $max_daily_pnl,
            max_stake_per_trade => $max_stake_per_trade
        };

        $client_limits->{$user_id} = $limit;
        $user_specific_limits->{clients} = $client_limits;

        $app_config->set({'quants.vanilla.user_specific_limits' => encode_json_utf8($user_specific_limits)});

        send_trading_ops_email(
            "Vanilla risk management tool: updated user specific config",
            {
                "loginid : $loginid", "max open position : $max_open_position", "max daily volume : $max_daily_volume",
                "max daily pnl : $max_daily_pnl"
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeVanillaPerClientConfig",
            "loginid : $loginid",
            "max open position : $max_open_position",
            "max daily volume : $max_daily_volume",
            "max daily pnl : $max_daily_pnl"
        );

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_vanilla_user_specific_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $user_specific_limits = decode_json_utf8($app_config->get('quants.vanilla.user_specific_limits'));
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
        $app_config->set({'quants.vanilla.user_specific_limits' => encode_json_utf8($user_specific_limits)});

        send_trading_ops_email("Vanilla risk management tool: deleted client limit ($loginid)", $limit);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $user_specific_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_vanilla_risk_profile')) {
    my $output;
    my $now        = time;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

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

        my $existing_risk_profile = decode_json_utf8($app_config->get("quants.vanilla.risk_profile.$risk_level"));

        if ($currency eq 'All') {
            foreach my $ccy (keys %{$existing_risk_profile}) {
                $existing_risk_profile->{$ccy} = $amount;
            }
        } else {
            $existing_risk_profile->{$currency} = $amount;
        }

        my $encoded_config = encode_json_utf8($existing_risk_profile);

        $app_config->set({"quants.vanilla.risk_profile.$risk_level" => $encoded_config});
        send_trading_ops_email("Vanilla risk management tool: updated risk profile", $existing_risk_profile);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeVanillaConfig", $existing_risk_profile);

        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_vanilla_per_symbol_config')) {
    my $output;
    my $now        = time;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }

    try {
        my $symbol                  = $r->param('symbol');
        my $vol_markup              = $r->param('vol_markup');
        my $spread_spot             = $r->param('spread_spot');
        my $delta_config            = $r->param('delta_config');
        my $bs_markup               = $r->param('bs_markup');
        my $max_strike_price_choice = $r->param('max_strike_price_choice');
        my $min_number_of_contracts = $r->param('min_number_of_contracts');
        my $max_number_of_contracts = $r->param('max_number_of_contracts');
        my $max_open_position       = $r->param('max_open_position');
        my $max_daily_volume        = $r->param('max_daily_volume');
        my $max_daily_pnl           = $r->param('max_daily_pnl');
        my $risk_profile            = $r->param('risk_profile');

        die "Symbol is not defined" if $symbol eq '';
        die "Vol markup must be a number"              unless looks_like_number($vol_markup);
        die "Spread spot must be a number"             unless looks_like_number($spread_spot);
        die "BS markup must be a number"               unless looks_like_number($bs_markup);
        die "max strike price choice must be a number" unless looks_like_number($max_strike_price_choice);
        die "max open position must be a number"       unless looks_like_number($max_open_position);
        die "max daily volume must be a number"        unless looks_like_number($max_daily_volume);
        die "max daily pnl must be a number"           unless looks_like_number($max_daily_pnl);
        die "max open position cannot be negative" if ($max_open_position < 0);
        die "max daily volume cannot be negative"  if ($max_daily_volume < 0);
        die "max daily pnl cannot be negative"     if ($max_daily_pnl < 0);

        unless ($risk_profile ~~ ['low_risk', 'medium_risk', 'moderate_risk', 'high_risk', 'extreme_risk', 'no_business']) {
            die 'risk profile is incorrect';
        }

        my $vanilla_config = decode_json_utf8($app_config->get("quants.vanilla.per_symbol_config.$symbol"));
        $vanilla_config = {
            vol_markup              => $vol_markup,
            spread_spot             => $spread_spot,
            delta_config            => decode_json_utf8($delta_config),
            bs_markup               => $bs_markup,
            max_strike_price_choice => $max_strike_price_choice,
            min_number_of_contracts => decode_json_utf8($min_number_of_contracts),
            max_number_of_contracts => decode_json_utf8($max_number_of_contracts),
            max_open_position       => $max_open_position,
            max_daily_volume        => $max_daily_volume,
            max_daily_pnl           => $max_daily_pnl,
            risk_profile            => $risk_profile,
        };

        my $encoded_vanilla_config = encode_json_utf8($vanilla_config);
        $app_config->set({"quants.vanilla.per_symbol_config.$symbol" => $encoded_vanilla_config});

        send_trading_ops_email("Vanilla risk management tool: updated $symbol configuration", $vanilla_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeVanillaConfig", $vanilla_config);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_vanilla_fx_per_symbol_config')) {
    my $output;
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }

    try {
        my $symbol                  = $r->param('symbol');
        my $delta_config            = $r->param('delta_config');
        my $max_strike_price_choice = $r->param('max_strike_price_choice');
        my $min_number_of_contracts = $r->param('min_number_of_contracts');
        my $max_number_of_contracts = $r->param('max_number_of_contracts');
        my $max_open_position       = $r->param('max_open_position');
        my $max_daily_volume        = $r->param('max_daily_volume');
        my $max_daily_pnl           = $r->param('max_daily_pnl');
        my $risk_profile            = $r->param('risk_profile');
        my $maturities_days         = $r->param('maturities_days');
        my $maturities_weeks        = $r->param('maturities_weeks');

        die "Symbol is not defined" if $symbol eq '';
        die "max strike price choice must be a number" unless looks_like_number($max_strike_price_choice);
        die "max open position must be a number"       unless looks_like_number($max_open_position);
        die "max daily volume must be a number"        unless looks_like_number($max_daily_volume);
        die "max daily pnl must be a number"           unless looks_like_number($max_daily_pnl);

        die 'risk profile is incorrec'
            unless ($risk_profile ~~ ['low_risk', 'medium_risk', 'moderate_risk', 'high_risk', 'extreme_risk', 'no_business']);

        my $vanilla_config = decode_json_utf8($app_config->get("quants.vanilla.fx_per_symbol_config.$symbol"));

        my $existing_spread_spot = delete $vanilla_config->{spread_spot};
        my $existing_spread_vol  = delete $vanilla_config->{spread_vol};

        my ($new_spread_spot, $new_spread_vol);
        # remove the maturities offered in spread spot and spread vol
        foreach my $delta (@{decode_json_utf8($delta_config)}) {
            foreach my $day (@{decode_json_utf8($maturities_days)}) {
                $new_spread_spot->{delta}->{$delta}->{day}->{$day} = $existing_spread_spot->{delta}->{$delta}->{day}->{$day};
                $new_spread_vol->{delta}->{$delta}->{day}->{$day}  = $existing_spread_vol->{delta}->{$delta}->{day}->{$day};
            }
            foreach my $week (@{decode_json_utf8($maturities_weeks)}) {
                $new_spread_spot->{delta}->{$delta}->{week}->{$week} = $existing_spread_spot->{delta}->{$delta}->{week}->{$week};
                $new_spread_vol->{delta}->{$delta}->{week}->{$week}  = $existing_spread_vol->{delta}->{$delta}->{week}->{$week};
            }
        }

        $vanilla_config = {
            delta_config             => decode_json_utf8($delta_config),
            max_strike_price_choice  => $max_strike_price_choice,
            min_number_of_contracts  => decode_json_utf8($min_number_of_contracts),
            max_number_of_contracts  => decode_json_utf8($max_number_of_contracts),
            max_open_position        => $max_open_position,
            max_daily_volume         => $max_daily_volume,
            max_daily_pnl            => $max_daily_pnl,
            risk_profile             => $risk_profile,
            maturities_allowed_days  => decode_json_utf8($maturities_days),
            maturities_allowed_weeks => decode_json_utf8($maturities_weeks),
            spread_spot              => $new_spread_spot,
            spread_vol               => $new_spread_vol,
        };

        my $encoded_vanilla_config = encode_json_utf8($vanilla_config);
        $app_config->set({"quants.vanilla.fx_per_symbol_config.$symbol" => $encoded_vanilla_config});

        send_trading_ops_email("Vanilla risk management tool: updated $symbol configuration", $vanilla_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeVanillaConfig", $vanilla_config);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_vanilla_fx_spread_specific_time')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my ($output, $spread_spot, $spread_vol, $underlying, $delta, $maturity, $start_time, $end_time);

    try {
        $start_time  = $r->param('start_time');
        $end_time    = $r->param('end_time');
        $underlying  = $r->param('underlying');
        $delta       = $r->param('delta');
        $maturity    = $r->param('maturity');
        $spread_spot = $r->param('spread_spot');
        $spread_vol  = $r->param('spread_vol');

        die 'Start time does not match date utility format' unless Date::Utility->new($start_time);
        die 'End time does not match date utility format'   unless Date::Utility->new($end_time);
        die 'Start time must be smaller than end time'      unless Date::Utility->new($start_time)->is_before(Date::Utility->new($end_time));

        die 'Spread must be a number' unless looks_like_number($spread_spot);
        die 'Spread must be a number' unless looks_like_number($spread_vol);

        die 'Invalid Maturity' unless ($maturity =~ /\d(D|W)/);    #regex match 1D , 7W etc

        die 'Delta must be a number'        unless looks_like_number($delta);
        die 'Delta must be between 0 and 1' unless ((0 < $delta) and ($delta < 1));

        my $fx_spread_specific_time = decode_json_utf8($app_config->get('quants.vanilla.fx_spread_specific_time'));

        my $id = substr(md5_hex($start_time, $end_time, $underlying, $delta, $maturity, $spread_spot, $spread_vol), 0, 16);

        $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id} = {
            start_time  => $start_time,
            end_time    => $end_time,
            spread_spot => $spread_spot,
            spread_vol  => $spread_vol
        };

        $app_config->set({'quants.vanilla.fx_spread_specific_time' => encode_json_utf8($fx_spread_specific_time)});

        send_trading_ops_email(
            "Vanilla risk management tool: updated vanilla fx specific time spread config",
            {
                start_time  => $start_time,
                end_time    => $end_time,
                underlying  => $underlying,
                delta       => $delta,
                spread_spot => $spread_spot,
                spread_vol  => $spread_vol
            });

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeVanillaFxSpecificTimeSpreadConfig",
                  "start time : $start_time \n"
                . "end time : $end_time \n"
                . "underlying :  $underlying \n"
                . "delta : $delta \n"
                . "spread spot : $spread_spot \n"
                . "spread vol : $spread_vol");

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_vanilla_fx_spread_specific_time')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my ($output, $id, $underlying, $delta, $maturity);

    try {
        $id         = $r->param('id');
        $underlying = $r->param('underlying');
        $delta      = $r->param('delta');
        $maturity   = $r->param('maturity');

        my $fx_spread_specific_time = decode_json_utf8($app_config->get('quants.vanilla.fx_spread_specific_time'));

        delete $fx_spread_specific_time->{$underlying}->{$delta}->{$maturity}->{$id};

        $app_config->set({'quants.vanilla.fx_spread_specific_time' => encode_json_utf8($fx_spread_specific_time)});

        send_trading_ops_email("Vanilla risk management tool: delete vanilla fx specific time spread config", {id => $id});

        BOM::Backoffice::QuantsAuditLog::log($staff, "RemovedVanillaFxSpecificTimeSpreadConfig", "id time : $id \n");

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_vanilla_fx_spread')) {

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my ($output, $symbol, $spread_config);
    try {
        $symbol        = $r->param('symbol');
        $spread_config = decode_json_utf8($r->param('spread_config'));

        # Rearranging the convoluted json here to match with our schema
        my $spread_spot_to_send;
        my $spread_vol_to_send;
        foreach my $delta (keys %{$spread_config}) {
            foreach my $maturity (keys %{$spread_config->{$delta}}) {
                my $spread_spot = $spread_config->{$delta}->{$maturity}->{spot};
                my $spread_vol  = $spread_config->{$delta}->{$maturity}->{vol};

                my $maturity_type = chop($maturity);    #D or W

                if ($maturity_type eq 'D') {
                    $spread_spot_to_send->{delta}->{$delta}->{day}->{$maturity} = $spread_spot;
                    $spread_vol_to_send->{delta}->{$delta}->{day}->{$maturity}  = $spread_vol;
                } else {
                    $spread_spot_to_send->{delta}->{$delta}->{week}->{$maturity} = $spread_spot;
                    $spread_vol_to_send->{delta}->{$delta}->{week}->{$maturity}  = $spread_vol;
                }

            }
        }

        my $vanilla_config = decode_json_utf8($app_config->get("quants.vanilla.fx_per_symbol_config.$symbol"));

        $vanilla_config->{spread_spot} = $spread_spot_to_send;
        $vanilla_config->{spread_vol}  = $spread_vol_to_send;

        my $encoded_vanilla_config = encode_json_utf8($vanilla_config);
        $app_config->set({"quants.vanilla.fx_per_symbol_config.$symbol" => $encoded_vanilla_config});

        send_trading_ops_email("Vanilla risk management tool: updated vanilla spread config", {pp($vanilla_config)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeVanillaFxSpreadConfig", pp($vanilla_config));

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

