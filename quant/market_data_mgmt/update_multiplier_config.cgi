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
use Scalar::Util qw(looks_like_number);
use Digest::MD5 qw(md5_hex);

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($r->param('save_multiplier_config')) {
    my $qc = BOM::Config::QuantsConfig->new(
        recorded_date    => Date::Utility->new,
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );
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
        $qc->save_config("multiplier_config::$symbol", $multiplier_config);

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeMultiplierConfig", $multiplier_config);
        $output = {success => 1};
    }
    catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_user_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $client_limits        = $custom_volume_limits->{clients} // {};
    my $qc                   = BOM::Config::QuantsConfig->new(
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
    );
    my $output;
    try {
        my $loginid = $r->param('loginid') // die 'loginid is undef';
        die "loginid is required" if !$loginid;

        my $volume_limit = $r->param('volume_limit') // die 'volume_limit is undef';
        die "volume limit is required" if !defined $volume_limit;
        die "volume limit must be numeric" if !looks_like_number($volume_limit);

        my $symbol = $r->param('symbol');
        for my $sym (split ',', $symbol) {
            die "symbol '$sym' is not valid" if $sym && !$qc->get_config('multiplier_config::' . $sym);
        }

        my $comment = $r->param('comment') // '';

        my $client = eval { BOM::User::Client->new({loginid => $loginid}) };
        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        my $limit = {
            loginid      => $loginid,
            volume_limit => $volume_limit
        };
        $limit->{symbol}  = $symbol  if $symbol;
        $limit->{comment} = $comment if $comment;

        my $uniq_key = substr(md5_hex($loginid . ($symbol // '')), 0, 16);
        $limit->{uniq_key} = $uniq_key;

        $client_limits->{$user_id}{$uniq_key} = $limit;
        $custom_volume_limits->{clients} = $client_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    }
    catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_multiplier_user_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $client_limits = $custom_volume_limits->{clients} // {};
    my $output;
    try {
        my $loginid  = $r->param('loginid');
        my $uniq_key = $r->param('uniq_key');

        my $client = eval { BOM::User::Client->new({loginid => $loginid}) };
        die "invalid loginid " . $loginid unless $client;
        my $user_id = 'binary_user_id::' . $client->binary_user_id;

        die "limit not found" unless $client_limits->{$user_id}{$uniq_key};
        delete $client_limits->{$user_id}{$uniq_key};

        $custom_volume_limits->{clients} = $client_limits;
        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    }
    catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('save_multiplier_market_or_underlying_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $market_limits        = $custom_volume_limits->{markets} // {};
    my $symbol_limits        = $custom_volume_limits->{symbols} // {};
    my $qc                   = BOM::Config::QuantsConfig->new(
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
    );
    my $output;
    try {
        my $limit_defs   = BOM::Config::quants()->{risk_profile};
        my $risk_profile = $r->param('risk_profile');
        die "invalid risk_profile" unless $risk_profile and $limit_defs->{$risk_profile};

        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        my $max_volume_positions = $r->param('max_volume_positions');
        die "max_volume_positions is required"     if !$max_volume_positions;
        die "max_volume_positions must be numeric" if !looks_like_number($max_volume_positions);
        die "max_volume_positions is too large"    if $max_volume_positions > 10;

        die "market and symbol can not be both set"   if $market  && $symbol;
        die "market and symbol can not be both empty" if !$market && !$symbol;

        if ($market) {
            $market_limits->{$market} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        } elsif ($symbol) {
            $symbol_limits->{$symbol} = {
                risk_profile         => $risk_profile,
                max_volume_positions => $max_volume_positions
            };
        }
        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    }
    catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}

if ($r->param('delete_multiplier_market_or_underlying_limit')) {
    my $app_config = BOM::Config::Runtime->instance->app_config;
    $app_config->chronicle_writer(BOM::Config::Chronicle::get_chronicle_writer());

    my $custom_volume_limits = decode_json_utf8($app_config->get('quants.custom_volume_limits'));
    my $market_limits        = $custom_volume_limits->{markets} // {};
    my $symbol_limits        = $custom_volume_limits->{symbols} // {};
    my $qc                   = BOM::Config::QuantsConfig->new(
        recorded_date    => Date::Utility->new,
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
    );
    my $output;
    try {
        my $market = $r->param('market');
        my $symbol = $r->param('symbol');

        if    ($market) { delete $market_limits->{$market}; }
        elsif ($symbol) { delete $symbol_limits->{$symbol}; }
        else            { die "market and symbol can not be both empty"; }

        $custom_volume_limits->{markets} = $market_limits;
        $custom_volume_limits->{symbols} = $symbol_limits;

        $app_config->set({'quants.custom_volume_limits' => encode_json_utf8($custom_volume_limits)});

        BOM::Backoffice::QuantsAuditLog::log($staff, "ChangeCustomVolumeLimits", $custom_volume_limits);
        $output = {success => 1};
    }
    catch {
        $output = {error => "$@"};
    }

    print encode_json_utf8($output);
}
