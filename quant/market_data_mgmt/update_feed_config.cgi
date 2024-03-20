#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use Data::Dump               qw(pp);
use JSON::MaybeUTF8          qw(:v1);
use Scalar::Util             qw(looks_like_number);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::Auth;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail                        qw(send_trading_ops_email);
use Log::Any                                                 qw($log);
use BOM::Backoffice::Quant::FeedConfiguration                qw(save_drift_switch_spread);
use BOM::Backoffice::Quant::FeedConfiguration::TacticalIndex qw(save_tactical_index_params update_tactical_index_spread);
use BOM::DualControl;
use BOM::User::AuditLog;

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth::get_staffname();
my $r     = request();

my $is_quant   = BOM::Backoffice::Auth::has_quants_write_access();
my $is_dealing = BOM::Backoffice::Auth::has_authorisation(['DealingWrite']);

if ($r->param('save_feed_drift_switch_spread_configuration')) {

    my ($output, $symbol, $commission_0, $commission_1, $perf);
    try {
        $symbol       = $r->param('symbol');
        $commission_0 = $r->param('commission_0');
        $commission_1 = $r->param('commission_1');
        $perf         = $r->param('perf');

        # Adding \n will prevent the line number being printed on UI
        die "Commission min must be a number that is bigger or equal than 0 \n" unless (looks_like_number($commission_0) && $commission_0 >= 0);
        die "Commission max must be a number that is bigger or equal than 0 \n" unless (looks_like_number($commission_1) && $commission_1 >= 0);
        die "Perf must be a number that is bigger or equal than 0 \n"           unless (looks_like_number($perf)         && $perf >= 0);
        die "Commission max must be bigger than Commission min \n"              unless $commission_1 >= $commission_0;

        save_drift_switch_spread($symbol, $commission_0, $commission_1, $perf);

        send_trading_ops_email(
            "Feed configuration management tool: updated spread for drift switch index",
            {
                symbol       => $symbol,
                commission_0 => $commission_0,
                commission_1 => $commission_1,
                perf         => $perf
            });
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeFeedConfiguration",
            "symbol : $symbol, commission_0 : $commission_0, commission_1 : $commission_1, perf : $perf");

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_tactical_index_params')) {

    my $output;

    try {
        my $symbol              = $r->param('symbol');
        my $lb_period           = $r->param('lb_period');
        my $lb_period_secondary = $r->param('lb_period_secondary');
        my $buy_leverage        = $r->param('buy_leverage');
        my $sell_leverage       = $r->param('sell_leverage');
        my $upper_level         = $r->param('upper_level');
        my $lower_level         = $r->param('lower_level');
        my $rebalancing_tick    = $r->param('rebalancing_tick');
        my $transition_state    = $r->param('transition_state');

        my $json_payload = {
            symbol              => $symbol,
            lb_period           => $lb_period,
            lb_period_secondary => $lb_period_secondary,
            buy_leverage        => $buy_leverage,
            sell_leverage       => $sell_leverage,
            upper_level         => $upper_level,
            lower_level         => $lower_level,
            rebalancing_tick    => $rebalancing_tick,
            transition_state    => $transition_state
        };

        $json_payload = encode_json_utf8($json_payload);
        my $dcc_error = BOM::DualControl->new({
                staff           => $staff,
                transactiontype => 'QuantsDCC'
            })->validate_tactical_index_control_code($r->param('quants_dcc'), $json_payload);

        die $dcc_error->get_mesg() . "\n" if $dcc_error;

        die "symbol must be a string. \n"                                   unless $symbol;
        die "lb_period must be a number that is bigger or equal than 0. \n" unless (looks_like_number($lb_period) && $lb_period >= 0);
        die "lb_period_secondary must be a number that is bigger or equal than 0. \n"
            unless (looks_like_number($lb_period_secondary) && $lb_period_secondary >= 0);
        die "buy_leverage must be a number that is bigger or equal than 0. \n"  unless (looks_like_number($buy_leverage)  && $buy_leverage >= 0);
        die "sell_leverage must be a number that is bigger or equal than 0. \n" unless (looks_like_number($sell_leverage) && $sell_leverage >= 0);
        die "upper_level must be a number that is bigger or equal than 0. \n"   unless (looks_like_number($upper_level)   && $upper_level >= 0);
        die "lower_level must be a number that is bigger or equal than 0. \n"   unless (looks_like_number($lower_level)   && $lower_level >= 0);
        die "rebalancing_tick must be a number that is bigger or equal than 0. \n"
            unless (looks_like_number($rebalancing_tick) && $rebalancing_tick >= 0);
        die "transition_state must be a number that is bigger or equal than 0. \n"
            unless (looks_like_number($transition_state) && $transition_state >= 0);

        my $args = {
            underlying          => $symbol,
            lb_period           => $lb_period,
            lb_period_secondary => $lb_period_secondary,
            buy_leverage        => $buy_leverage,
            sell_leverage       => $sell_leverage,
            upper_level         => $upper_level,
            lower_level         => $lower_level,
            rebalancing_tick    => $rebalancing_tick,
            transition_state    => $transition_state,
        };

        save_tactical_index_params($symbol, $args);

        send_trading_ops_email(
            "Feed configuration management tool: updated index parameters for tactical index",
            {
                symbol              => $symbol,
                lb_period           => $lb_period,
                lb_period_secondary => $lb_period_secondary,
                buy_leverage        => $buy_leverage,
                sell_leverage       => $sell_leverage,
                upper_level         => $upper_level,
                lower_level         => $lower_level,
                rebalancing_tick    => $rebalancing_tick,
                transition_state    => $transition_state,
            });

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeFeedConfiguration", pp($args));

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_tactical_index_spread')) {

    my $output;
    unless ($is_quant || $is_dealing) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }

    try {
        my $symbol      = $r->param('symbol');
        my $alpha       = $r->param('alpha');
        my $calibration = $r->param('calibration');
        my $commission  = $r->param('commission');

        die "symbol must be a string. \n"                                     unless $symbol;
        die "alpha must be a number that is bigger or equal than 0. \n"       unless (looks_like_number($alpha)       && $alpha >= 0);
        die "calibration must be a number that is bigger or equal than 0. \n" unless (looks_like_number($calibration) && $calibration >= 0);
        die "commission must be a number that is bigger or equal than 0. \n"  unless (looks_like_number($commission)  && $commission >= 0);

        update_tactical_index_spread($symbol, $alpha, $calibration, $commission);

        send_trading_ops_email(
            "Feed configuration management tool: updated index parameters for tactical index",
            {
                symbol      => $symbol,
                alpha       => $alpha,
                calibration => $calibration,
                commission  => $commission,
            });

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeFeedConfiguration",
            "symbol : $symbol, alpha : $alpha, calibration : $calibration, commission : $commission");

        $output = {success => 1};
    } catch ($e) {
        $output = {error => "$e"};
    }

    print encode_json_utf8($output);

}

