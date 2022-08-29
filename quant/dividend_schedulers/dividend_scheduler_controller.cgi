#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open                     qw[ :encoding(UTF-8) ];
use lib                      qw(/home/git/regentmarkets/bom-backoffice);
use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use Syntax::Keyword::Try;
use BOM::Backoffice::QuantsAuditEmail qw(send_trading_ops_email);
use BOM::Backoffice::Request          qw(request);
use BOM::Backoffice::DividendSchedulerTool;

BOM::Backoffice::Sysinit::init();
my $r = request();

if ($r->param('create_dividend_scheduler')) {
    my $args = {
        platform_type         => $r->param('platform_type'),
        server_name           => $r->param('server_name'),
        symbol                => $r->param('symbol'),
        currency              => $r->param('currency'),
        long_dividend         => $r->param('long_dividend'),
        short_dividend        => $r->param('short_dividend'),
        long_tax              => $r->param('long_tax'),
        short_tax             => $r->param('short_tax'),
        dividend_deal_comment => $r->param('dividend_deal_comment'),
        applied_datetime      => $r->param('applied_datetime'),
        skip_holiday_check    => $r->param('skip_holiday_check'),
    };

    my $validated_arg = BOM::Backoffice::DividendSchedulerTool::validate_params($args);

    if (defined $validated_arg->{error}) {
        return print encode_json_utf8({error => $validated_arg->{error}});
    }

    my $result = BOM::Backoffice::DividendSchedulerTool::create($validated_arg);

    my $output;
    if ($result->{success}) {
        $output = {success => 1};
    } else {
        $output = {error => $result->{error}};
    }

    print encode_json_utf8($output);
}

if ($r->param('update_dividend_scheduler')) {
    my $args = {
        update                => 1,
        schedule_id           => $r->param('schedule_id'),
        platform_type         => $r->param('platform_type'),
        server_name           => $r->param('server_name'),
        symbol                => $r->param('symbol'),
        currency              => $r->param('currency'),
        long_dividend         => $r->param('long_dividend'),
        short_dividend        => $r->param('short_dividend'),
        long_tax              => $r->param('long_tax'),
        short_tax             => $r->param('short_tax'),
        dividend_deal_comment => $r->param('dividend_deal_comment'),
        applied_datetime      => $r->param('applied_datetime'),
        skip_holiday_check    => $r->param('skip_holiday_check'),
    };

    my $validated_arg = BOM::Backoffice::DividendSchedulerTool::validate_params($args);

    if (defined $validated_arg->{error}) {
        return print encode_json_utf8({error => $validated_arg->{error}});
    }

    my $result = BOM::Backoffice::DividendSchedulerTool::update($validated_arg);

    my $output;
    if ($result->{success}) {
        $output = {success => 1};
    } else {
        $output = {error => $result->{error}};
    }

    print encode_json_utf8($output);
}

if ($r->param('destroy_dividend_scheduler')) {
    my $args = {
        schedule_id => $r->param('schedule_id'),
    };

    my $result = BOM::Backoffice::DividendSchedulerTool::destroy($args);

    my $output;
    if ($result->{success}) {
        $output = {success => 1};
    } else {
        $output = {error => $result->{error}};
    }

    print encode_json_utf8($output);
}

if ($r->param('set_currency_symbol')) {
    my $symbol = $r->param('symbol');
    my $args   = {
        symbol => $symbol,
    };

    my $result = BOM::Backoffice::DividendSchedulerTool::set_currency_symbol($args);

    my $output;
    if ($result->{success}) {
        $output = $result;
    } else {
        $output = {error => "The currency for symbol $symbol is missing. Please contact Quants Dev!!"};
    }

    print encode_json_utf8($output);
}
