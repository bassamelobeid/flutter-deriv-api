#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth0;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Request qw(request);
use Text::Trim               qw(trim);
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

my $app_config = BOM::Config::Runtime->instance->app_config;
$app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

if ($r->param('save_accumulator_config')) {
    my $output;
    my $now = time;

    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }
    try {
        my $symbol             = $r->param('symbol')          // die 'symbol is undef';
        my $landing_company    = $r->param('landing_company') // die 'landing_company is undef';
        my $accumulator_config = decode_json_utf8($app_config->get("quants.accumulator.symbol_config.$landing_company.$symbol"));
        my $tick_size_barrier  = LoadFile('/home/git/regentmarkets/bom-config/share/default_tick_size_barrier_accumulator.yml');
        my $growth_rate        = decode_json_utf8($r->param('growth_rate'));
        my @unique_growth_rate = uniq @$growth_rate;

        #checking if there exists tick size barrier for each growth rate
        foreach my $gr (@unique_growth_rate) {
            unless (exists($tick_size_barrier->{$symbol}{"growth_rate_" . $gr})) {
                $output = {error => "There is no tick size barrier defined for $gr growth rate"};
                print encode_json_utf8($output);
                return;
            }
        }

        $accumulator_config->{$now} = {
            max_payout               => decode_json_utf8($r->param('max_payout')),
            max_duration_coefficient => $r->param('max_duration_coefficient'),
            growth_start_step        => $r->param('growth_start_step'),
            growth_rate              => \@unique_growth_rate
        };

        my $encoded_accumulator_config = encode_json_utf8($accumulator_config);
        $app_config->set({"quants.accumulator.symbol_config.$landing_company.$symbol" => $encoded_accumulator_config});
        send_trading_ops_email("Accumulator risk management tool: updated $symbol configuration", $accumulator_config->{$now});
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeAccumulatorConfig", $accumulator_config->{$now});
        $output = {success => 1};
    } catch ($e) {
        my ($message) = $e =~ /(.*)\sat\s\//;
        $output = {error => "$message"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_affiliate_commission')) {
    my $output;
    my $financial;
    my $non_financial;
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

if ($r->param('save_accumulator_client_limits')) {
    my $output;
    my $max_open_positions;
    my $max_daily_volume;
    try {
        $max_open_positions = $r->param('max_open_positions');
        $max_daily_volume   = $r->param('max_daily_volume');

        $app_config->set({'quants.accumulator.client_limits.max_open_positions' => $max_open_positions});
        $app_config->set({'quants.accumulator.client_limits.max_daily_volume'   => $max_daily_volume});

        send_trading_ops_email(
            "Accumulator risk management tool: updated accumulator client limits",
            {
                max_open_positions => $max_open_positions,
                max_daily_volume   => $max_daily_volume
            });
        BOM::Backoffice::QuantsAuditLog::log(
            $staff,
            "ChangeAccumulatorClientLimits",
            'max_open_positions : '
                . $max_open_positions
                . ', max_daily_volume :
            ' . $max_daily_volume
        );

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_accumulator_market_or_underlying_risk_profile')) {

    my $market_risk_profiles = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.market')) // {};
    my $symbol_risk_profiles = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.symbol')) // {};

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
            $app_config->set({'quants.accumulator.risk_profile.market' => encode_json_utf8($market_risk_profiles)});
        } elsif ($symbol) {
            $symbol_risk_profiles->{$symbol} = $risk_profile;
            $app_config->set({'quants.accumulator.risk_profile.symbol' => encode_json_utf8($symbol_risk_profiles)});
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

    my $market_risk_profiles = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.market')) // {};
    my $symbol_risk_profiles = decode_json_utf8($app_config->get('quants.accumulator.risk_profile.symbol')) // {};

    my $output;
    try {
        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        if ($market) {
            delete $market_risk_profiles->{$market};
            $app_config->set({'quants.accumulator.risk_profile.market' => encode_json_utf8($market_risk_profiles)});
        } elsif ($symbol) {
            delete $symbol_risk_profiles->{$symbol};
            $app_config->set({'quants.accumulator.risk_profile.symbol' => encode_json_utf8($symbol_risk_profiles)});
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
