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
use Syntax::Keyword::Try;
use BOM::Config::Runtime;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use Log::Any                          qw($log);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('save_accumulator_config')) {
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
        my $symbol             = $r->param('symbol')          // die 'symbol is undef';
        my $landing_company    = $r->param('landing_company') // die 'landing_company is undef';
        my $accumulator_config = decode_json_utf8($app_config->get("quants.accumulator.symbol_config.$landing_company.$symbol"));
        $accumulator_config->{$now} = {
            max_payout               => decode_json_utf8($r->param('max_payout')),
            max_duration_coefficient => $r->param('max_duration_coefficient'),
            growth_start_step        => $r->param('growth_start_step'),
            growth_rate              => decode_json_utf8($r->param('growth_rate'))};

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

    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

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

