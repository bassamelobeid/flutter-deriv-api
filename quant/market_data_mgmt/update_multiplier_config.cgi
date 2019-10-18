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

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

if ($r->param('save_multiplier_config')) {
    my $output = try {
        my $multiplier_config = decode_json_utf8($r->param('multiplier_config_json'));
        my $new_config;
        foreach my $c (@$multiplier_config) {
            my ($name, $value) = @{$c}{'name', 'value'};
            my ($symbol, $config_type) = split '-', $name;
            $new_config->{$symbol}{$config_type} = $config_type eq 'multiplier_range' ? decode_json_utf8($value) : $value;
        }
        BOM::Config::QuantsConfig->new(
            recorded_date    => Date::Utility->new,
            chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
        )->save_config('multiplier_config', $new_config);
        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeMultiplierConfig", $new_config);
        {success => 1};
    }
    catch {
        {error => 1};
    };

    print encode_json_utf8($output);
}
