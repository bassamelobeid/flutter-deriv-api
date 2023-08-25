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
use BOM::Backoffice::QuantsAuditEmail         qw(send_trading_ops_email);
use Log::Any                                  qw($log);
use BOM::Backoffice::Quant::FeedConfiguration qw(save_drift_switch_spread);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

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

