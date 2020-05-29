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

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('save_multiplier_config')) {
    my $output;
    if ($disabled_write) {
        $output = {error => "permission denied: no write access"};
        print encode_json_utf8($output);
        return;
    }
    try {
        my $symbol = $r->param('symbol') // die 'symbol is undef';
        my $multiplier_config = {
            commission                  => $r->param('commission'),
            multiplier_range            => decode_json_utf8($r->param('multiplier_range')),
            cancellation_commission     => $r->param('cancellation_commission'),
            cancellation_duration_range => decode_json_utf8($r->param('cancellation_duration_range')),
        };
        BOM::Config::QuantsConfig->new(
            recorded_date    => Date::Utility->new,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        )->save_config("multiplier_config::$symbol", $multiplier_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeMultiplierConfig", $multiplier_config);
        $output = {success => 1};
    }
    catch {
        $output = {error => 1};
    }

    print encode_json_utf8($output);
}
