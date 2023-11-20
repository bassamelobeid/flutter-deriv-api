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
use BOM::Backoffice::Auth;
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
use ExchangeRates::CurrencyConverter qw(in_usd convert_currency);
use Format::Util::Numbers            qw(financialrounding);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth::has_quants_write_access();

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
        my $accumulator_hard_limits = get_accumulator_hard_limits();
        my $symbol                  = $r->param('symbol') // die 'symbol is undef';
        my $tick_size_barrier       = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');
        my $growth_rate             = decode_json_utf8($r->param('growth_rate'));
        my $max_duration            = decode_json_utf8($r->param('max_duration'));
        my $max_payout              = decode_json_utf8($r->param('max_payout'));
        my @unique_growth_rate      = uniq @$growth_rate;
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

        # for max duration
        validate_growth_rate_cap($max_duration, $accumulator_hard_limits->{max_duration}, "duration");
        validate_payout($max_payout, $accumulator_hard_limits->{payout_per_trade}{min_value},
            $accumulator_hard_limits->{payout_per_trade}{max_value});

        my $per_symbol_config = {
            max_payout        => $max_payout,
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
        my $accumulator_hard_limits  = get_accumulator_hard_limits();
        my $symbol                   = $r->param('symbol') // die 'symbol is undef';
        my $max_open_positions       = $r->param('max_open_positions');
        my $max_daily_volume         = $r->param('max_daily_volume');
        my $max_aggregate_open_stake = decode_json_utf8($r->param('max_aggregate_open_stake'));

        validate_max_open_positions($max_open_positions, $accumulator_hard_limits->{max_open_positions}{max_value});
        validate_max_daily_volume($max_daily_volume);
        # for max aggregate open stake
        validate_growth_rate_cap($max_aggregate_open_stake, $accumulator_hard_limits->{max_aggregate_open_stake}, "aggregate");

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
        my $accumulator_hard_limits = get_accumulator_hard_limits();

        die "Loginid should be defined.\n" unless $loginid;
        die "Max daily pnl should be a number and bigger than 0.\n" if $max_daily_pnl and (!looks_like_number($max_daily_pnl) or $max_daily_pnl <= 0);
        validate_max_open_positions($max_open_positions, $accumulator_hard_limits->{max_open_positions}{max_value});
        validate_max_daily_volume($max_daily_volume);

        unless ($max_open_positions or $max_daily_volume or $max_daily_pnl or $max_stake_per_trade) {
            die "At least one limit field should be specified.\n";
        }

        my $client;
        try {
            $client = BOM::User::Client->new({loginid => $loginid});
        } catch ($e) {
            $log->warnf("Error when get client of login id $loginid. more detail: %s", $e);
        }

        die "invalid loginid " . $loginid unless $client;

        validate_max_stake_per_trade(
            $max_stake_per_trade,
            $accumulator_hard_limits->{stake_per_trade}{min_value},
            $accumulator_hard_limits->{stake_per_trade}{max_value});

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
        # it will capture $1 if dir location(at ./) is included in the error message otherwise simply return error ($e).
        my ($message) = $e =~ /(.*)\sat\s\// ? $1 : $e;
        $output = {error => "$message"};
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
        my $accumulator_hard_limits = get_accumulator_hard_limits();
        my $currency                = $r->param('currency');
        my $risk_level              = $r->param('risk_level');
        my $amount                  = $r->param('amount');

        validate_max_stake_per_trade(
            $amount,
            $accumulator_hard_limits->{stake_per_trade}{min_value},
            $accumulator_hard_limits->{stake_per_trade}{max_value});

        my $existing_risk_profile = $qc->get_max_stake_per_risk_profile($risk_level);
        my $exchange_amount;
        if ($currency eq 'All') {
            foreach my $ccy (keys %{$existing_risk_profile}) {
                $exchange_amount = convert_currency($amount, "USD", $ccy);
                $existing_risk_profile->{$ccy} = financialrounding("amount", $ccy, $exchange_amount);
            }
        } else {
            $exchange_amount = convert_currency($amount, "USD", $currency);
            $existing_risk_profile->{$currency} = financialrounding("amount", $currency, $exchange_amount);
        }

        my $redis_key = join('::', 'accumulator', 'max_stake_per_risk_profile', $risk_level);
        $qc->save_config($redis_key, $existing_risk_profile);

        send_trading_ops_email("Accumulator risk management tool: updated risk profile", $existing_risk_profile);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $existing_risk_profile);

        $output = {success => 1};
    } catch ($e) {
        # it will capture $1 if dir location(at ./) is included in the error message otherwise simply return error ($e).
        my ($message) = $e =~ /(.*)\sat\s\// ? $1 : $e;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_market_or_underlying_risk_profile')) {
    my $market_risk_profiles = $qc->get_risk_profile_per_market // {};
    my $symbol_risk_profiles = $qc->get_risk_profile_per_symbol // {};

    my $output;
    try {
        my $limit_defs = BOM::Config::quants()->{risk_profile};
        delete $limit_defs->{no_business};
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

=head2 validate_max_open_positions

Validation for max daily volumn and check if its a number and positive value.

=over 4

=item - $max_open_positions, scalar value to update max open positions.

=item - $max_open_positions_cap, max open positions allowed at a time. 

=back

=cut

sub validate_max_open_positions {
    my ($max_open_positions, $max_open_positions_cap) = @_;

    die "Max Open Positions must be $max_open_positions_cap." unless $max_open_positions == $max_open_positions_cap;
}

=head2 validate_max_daily_volume

Validation for max daily volumn and check if its a number and positive value.

=over 4

=item - $max_daily_volume, scalar value to updated max daily volumn. 

=back

Returns error if certain condition does not meet.

=cut

sub validate_max_daily_volume {
    my ($max_daily_volume) = @_;
    die "Max Daily Volume must be a number.\n" unless looks_like_number($max_daily_volume);
    die "Max Daily Volume must be a positive value.\n" if $max_daily_volume < 0;
}

=head2 validate_max_stake_per_trade

validate max stake per trade

=over 4

=item - $max_stake_per_trade, scalar value for stake_per_trade update.

=item - $min_stake_per_trade_cap, minimum stake_per_trade cap.

=item - $max_stake_per_trade_cap, maximum stake_per_trade cap.

=back

Returns error if new applied limit does not lie in between minimum and maximum cap.

=cut

sub validate_max_stake_per_trade {
    my ($max_stake_per_trade, $min_stake_per_trade_cap, $max_stake_per_trade_cap) = @_;
    if (   !$max_stake_per_trade
        || !looks_like_number($max_stake_per_trade)
        || $max_stake_per_trade < $min_stake_per_trade_cap
        || $max_stake_per_trade > $max_stake_per_trade_cap)
    {
        die "Stake per trade should be between $min_stake_per_trade_cap and $max_stake_per_trade_cap usd.\n";
    }
}

=head2 validate_growth_rate_cap

Description:  Perform validations based on accumulator hard limits.  
Takes the following arguments.

=over 4

=item - $growth_rate, hash ref containing new limits . 

=item - $growth_rate_cap, hash ref containing hard limits.

=item - $type, string value should contain aggregate/duration.

=back

Returns error if certain condition does not meet.

=cut

sub validate_growth_rate_cap {
    my ($growth_rate, $growth_rate_cap, $type) = @_;

    foreach my $key (keys %{$growth_rate_cap}) {
        my $growth_rate_value     = $growth_rate->{$key};
        my $growth_rate_value_cap = $growth_rate_cap->{$key};

        die "Max $type for $key should be betweeen 1 and  $growth_rate_value_cap."
            if $growth_rate_value > $growth_rate_value_cap || $growth_rate_value < 1;
    }
}

=head2 validate_payout

Description:  Perform validations based on accumulator hard limits.  
Takes the following arguments.

=over 4

=item - $payout, hash ref containing payouts for symbol. 

=item - $min_payout_cap, min payout cap for symbol.

=item - $max_payout_cap, maximum payout cap for symbol.

=back

Returns error if certain condition does not meet.

=cut

sub validate_payout {
    my ($payout, $min_payout_cap, $max_payout_cap) = @_;

    foreach my $key (keys %{$payout}) {
        my $payout_value    = $payout->{$key};
        my $exchange_amount = in_usd($payout_value, $key);

        if (   !$payout_value
            || !looks_like_number($payout_value)
            || $exchange_amount < $min_payout_cap
            || $exchange_amount > $max_payout_cap)
        {
            die "Payout per trade for $key should be between $min_payout_cap and $max_payout_cap usd. Current Exchange Amount: $exchange_amount usd.";
        }
    }
}

=head2 get_accumulator_hard_limits

Returns the hard limits imposed on symbol or clients for an accumulator. 
These limits are part of the Risk Management tool. 

=cut

sub get_accumulator_hard_limits {
    return LoadFile("/home/git/regentmarkets/bom-config/share/accumulator_hard_limits.yml");
}
