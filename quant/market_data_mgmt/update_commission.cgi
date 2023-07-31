#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib  qw(/home/git/regentmarkets/bom-backoffice);

use JSON::MaybeUTF8          qw(:v1);
use BOM::Backoffice::Sysinit ();
use BOM::Backoffice::CommissionTool;
use BOM::Backoffice::Auth0;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;

BOM::Backoffice::Sysinit::init();
my $staff = BOM::Backoffice::Auth0::get_staffname();
my $r     = request();

my $disabled_write = not BOM::Backoffice::Auth0::has_quants_write_access();

if ($disabled_write) {
    my $output = {error => "permission denied: no write access"};
    print encode_json_utf8($output);
    return;
}

if ($r->param('save_cfds_commission')) {
    my $output = BOM::Backoffice::CommissionTool::save_commission({
        provider        => $r->param('provider'),
        symbol          => $r->param('symbol'),
        account_type    => $r->param('account_type'),
        commission_type => $r->param('commission_type'),
        commission_rate => $r->param('commission_rate'),
        contract_size   => $r->param('contract_size'),
    });
    print encode_json_utf8($output);
}

if ($r->param('save_affiliate_payment')) {
    my $output = BOM::Backoffice::CommissionTool::save_affiliate_payment_details({
        provider        => $r->param('provider'),
        affiliate_id    => $r->param('affiliate_id'),
        payment_loginid => $r->param('payment_loginid'),
    });
    print encode_json_utf8($output);
}

if ($r->param('preview_affiliate_info')) {
    my $output = BOM::Backoffice::CommissionTool::get_affiliate_info({
        provider       => $r->param('provider'),
        affiliate_id   => $r->param('affiliate_id'),
        binary_user_id => $r->param('binary_user_id'),
    });
    print encode_json_utf8($output);
}

if ($r->param('preview_affiliate_transaction')) {
    my $output = BOM::Backoffice::CommissionTool::get_transaction_info({
        provider     => $r->param('provider'),
        affiliate_id => $r->param('affiliate_id'),
        date         => $r->param('date'),
        cfd_provider => $r->param('cfd_provider'),
        make_payment => $r->param('make_payment'),
        list_unpaid  => $r->param('list_unpaid'),
        hex          => $r->param('hex'),
    });
    print encode_json_utf8($output);
}

if ($r->param('commission_config_update')) {
    my $output = BOM::Backoffice::CommissionTool::update_commission_config({
        provider                  => $r->param('provider'),
        status                    => $r->param('status'),
        payment_status            => $r->param('payment_status'),
        commission_type_financial => $r->param('commission_type_financial'),
        commission_type_synthetic => $r->param('commission_type_synthetic'),
    });
    print encode_json_utf8($output);
}
