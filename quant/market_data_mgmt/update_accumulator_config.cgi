#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
use List::Util               qw(min max any);
use Scalar::Util             qw(looks_like_number);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Request qw(request);
use BOM::Config::QuantsConfig;
use BOM::Config;
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Log::Any                          qw($log);
use YAML::XS                          qw(LoadFile);
use List::Util                        qw(none uniq);
use Finance::Underlying;
use Finance::Underlying::Market::Registry;

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

my $qc = BOM::Config::QuantsConfig->new(
    contract_category => 'accumulator',
    recorded_date     => Date::Utility->new,
    chronicle_writer  => BOM::Config::Chronicle::get_chronicle_writer(),
    chronicle_reader  => BOM::Config::Chronicle::get_chronicle_reader(),
);

if ($r->param('save_accumulator_config')) {
    my $output;
    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }
    try {
        my $symbol             = $r->param('symbol') // die 'symbol is undef';
        my $tick_size_barrier  = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');
        my $growth_rate        = decode_json_utf8($r->param('growth_rate'));
        my $max_duration       = decode_json_utf8($r->param('max_duration'));
        my @unique_growth_rate = uniq @$growth_rate;
        #checking if there exists tick size barrier for each growth rate
        foreach my $gr (@unique_growth_rate) {
            unless (exists($tick_size_barrier->{$symbol}{"growth_rate_" . $gr})) {
                $output = {error => "There is no tick size barrier defined for $gr growth rate"};
                print encode_json_utf8($output);
                return;
            }
        }
        #checking the existence of growth_rate for the specified max_duration
        foreach my $gr (keys %$max_duration) {
            # an example of $gr: "growth_rate_0.01"
            my @gr_split = split("_", $gr);
            $gr = $gr_split[2];
            unless (any { $gr eq $_ } @$growth_rate) {
                $output = {error => "Growth rate $gr is not offered. So there shouldn't be any corresponding max duration value."};
                print encode_json_utf8($output);
                return;
            }
        }

        my $per_symbol_config = {
            max_payout        => decode_json_utf8($r->param('max_payout')),
            max_duration      => $max_duration,
            growth_start_step => $r->param('growth_start_step'),
            growth_rate       => \@unique_growth_rate
        };
        my $redis_key = join('::', 'accumulator', 'per_symbol', 'common', $symbol);
        $qc->save_config($redis_key, $per_symbol_config);
        send_trading_ops_email("Accumulator risk management tool: updated $symbol configuration", $per_symbol_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $per_symbol_config);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_per_symbol_limits')) {
    my $output;
    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }
    try {
        my $symbol             = $r->param('symbol') // die 'symbol is undef';
        my $max_open_positions = $r->param('max_open_positions');
        my $max_daily_volume   = $r->param('max_daily_volume');

        die "Max Open Positions must be a number" unless looks_like_number($max_open_positions);
        die "Max Open Positions must be a positive value" if $max_open_positions < 0;
        die "Max Dialy Volume must be a number" unless looks_like_number($max_daily_volume);
        die "Max Daily Volume must be a positive value" if $max_daily_volume < 0;

        my $per_symbol_limits = {
            max_open_positions       => $r->param('max_open_positions'),
            max_daily_volume         => $r->param('max_daily_volume'),
            max_aggregate_open_stake => decode_json_utf8($r->param('max_aggregate_open_stake'))};
        my $redis_key = join('::', 'accumulator', 'per_symbol_limits', 'common', $symbol);
        $qc->save_config($redis_key, $per_symbol_limits);
        send_trading_ops_email("Accumulator risk management tool: updated $symbol limits configuration", $per_symbol_limits);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $per_symbol_limits);
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_user_specific_limits')) {
    my $output;
    my $max_open_positions;
    my $max_daily_volume;
    my $max_daily_pnl;
    my $max_stake_per_trade;
    my $loginid;
    try {
        $loginid             = $r->param('loginid');
        $max_open_positions  = $r->param('max_open_positions');
        $max_daily_volume    = $r->param('max_daily_volume');
        $max_daily_pnl       = $r->param('max_daily_pnl');
        $max_stake_per_trade = $r->param('max_stake_per_trade');

        die 'Loginid should be defined' unless $loginid;
        die 'Max open positions should be a number and bigger than 0'
            if $max_open_positions and (!looks_like_number($max_open_positions) or $max_open_positions <= 0);
        die 'Max daily volume should be a number and bigger than 0'
            if $max_daily_volume and (!looks_like_number($max_daily_volume) or $max_daily_volume <= 0);
        die 'Max daily pnl should be a number and bigger than 0' if $max_daily_pnl and (!looks_like_number($max_daily_pnl) or $max_daily_pnl <= 0);
        die 'Max stake per trade should be a number and bigger than 0'
            if $max_stake_per_trade and (!looks_like_number($max_stake_per_trade) or $max_stake_per_trade <= 0);

        unless ($max_open_positions or $max_daily_volume or $max_daily_pnl or $max_stake_per_trade) {
            die 'At least one limit field should be specified.';
        }

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
            loginid             => $loginid,
            max_open_positions  => $max_open_positions,
            max_daily_volume    => $max_daily_volume,
            max_daily_pnl       => $max_daily_pnl,
            max_stake_per_trade => $max_stake_per_trade,
        };

        delete $limit->{max_open_positions}  unless $limit->{max_open_positions};
        delete $limit->{max_daily_volume}    unless $limit->{max_daily_volume};
        delete $limit->{max_daily_pnl}       unless $limit->{max_daily_pnl};
        delete $limit->{max_stake_per_trade} unless $limit->{max_stake_per_trade};

        $client_limits->{$user_id} = $limit;
        $user_specific_limits->{clients} = $client_limits;

        my $redis_key = join('::', 'accumulator', 'user_specific_limits');
        $qc->save_config($redis_key, $user_specific_limits);

        send_trading_ops_email("Accumulator risk management tool: updated client with $loginid configuration", $limit);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $limit);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_accumulator_user_specific_limit')) {
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

        my $redis_key = join('::', 'accumulator', 'user_specific_limits');
        $qc->save_config($redis_key, $user_specific_limits);

        send_trading_ops_email("Accumulator risk management tool: deleted client limit ($loginid)", $limit);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $user_specific_limits);
        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_affiliate_commission')) {
    my $output;
    my $financial;
    my $non_financial;

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    try {
        $financial     = $r->param('financial');
        $non_financial = $r->param('non_financial');

        die "Commission must be within the range [0,1)" if ($financial < 0 or $financial >= 1) or ($non_financial < 0 or $non_financial >= 1);

        $app_config->set({'quants.accumulator.affiliate_commission.financial'     => $financial});
        $app_config->set({'quants.accumulator.affiliate_commission.non_financial' => $non_financial});

        send_trading_ops_email(
            "Accumulator risk management tool: updated affiliate commission",
            {
                financial     => $financial,
                non_financial => $non_financial
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAffiliateAccumulatorCommission",
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

if ($r->param('save_accumulator_risk_profile')) {
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

        my $redis_key = join('::', 'accumulator', 'max_stake_per_risk_profile', $risk_level);
        $qc->save_config($redis_key, $existing_risk_profile);

        send_trading_ops_email("Accumulator risk management tool: updated risk profile", $existing_risk_profile);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $existing_risk_profile);

        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_market_or_underlying_risk_profile')) {
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
            my $redis_key = join('::', 'accumulator', 'risk_profile_per_market');
            $qc->save_config($redis_key, $market_risk_profiles);
        } elsif ($symbol) {
            $symbol_risk_profiles->{$symbol} = $risk_profile;
            my $redis_key = join('::', 'accumulator', 'risk_profile_per_symbol');
            $qc->save_config($redis_key, $symbol_risk_profiles);
        }

        my $res = $market ? $market_risk_profiles : $symbol_risk_profiles;
        send_trading_ops_email("Accumulator risk management tool: updated risk profiles", $res);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeRiskProfiles", $res);

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }
    print encode_json_utf8($output);

}

if ($r->param('delete_accumulator_market_or_underlying_risk_profile')) {
    my $market_risk_profiles = $qc->get_risk_profile_per_market // {};
    my $symbol_risk_profiles = $qc->get_risk_profile_per_symbol // {};

    my $output;
    try {
        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        if ($market) {
            delete $market_risk_profiles->{$market};
            my $redis_key = join('::', 'accumulator', 'risk_profile_per_market');
            $qc->save_config($redis_key, $market_risk_profiles);
        } elsif ($symbol) {
            delete $symbol_risk_profiles->{$symbol};
            my $redis_key = join('::', 'accumulator', 'risk_profile_per_symbol');
            $qc->save_config($redis_key, $market_risk_profiles);
        } else {
            die "market and symbol can not be both empty";
        }

        my $res = $market ? $market_risk_profiles : $symbol_risk_profiles;
        send_trading_ops_email("Accumulator risk management tool: deleted custom risk profiles", $res);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeRiskProfiles", $res);

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}
