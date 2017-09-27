#!/etc/rmg/bin/perl
package main;
use strict;
use warnings;

use HTML::Entities;
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use SuperDerivatives::Correlation qw( upload_and_process_correlations );
use subs::subs_dividend_from_excel_file;
use BOM::Backoffice::Sysinit ();
use BOM::Platform::Chronicle;
use Try::Tiny;
BOM::Backoffice::Sysinit::init();
use BOM::Platform::Config;

PrintContentType();
BrokerPresentation("QUANT BACKOFFICE");

use BOM::Platform::Config;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Backoffice::Request qw(request);
use Quant::Framework::CorrelationMatrix;
use BOM::MarketDataAutoUpdater::Forex;
my $broker = request()->broker_code;

if ($broker !~ /^\w+$/) { die "Bad broker code $broker in $0"; }

unless ((grep { $_ eq 'binary_role_master_server' } @{BOM::Platform::Config::node()->{node}->{roles}})) {
    code_exit_BO();
}

# Upload Dividend
# Currently we can get a list of forecast dividend from Bloomberg but in excel format
Bar("Upload Dividend");
print generate_dividend_upload_form({
    broker     => $broker,
    upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
});

if (request()->param('whattodo') and request()->param('whattodo') eq 'process_dividend') {
    my $cgi                      = CGI->new;
    my $filetoupload             = $cgi->param('filetoupload');
    my $update_discrete_dividend = request()->param('update_discrete_dividend');
    print process_dividend($filetoupload, $update_discrete_dividend);
}

Bar("Upload Correlations");
print generate_correlations_upload_form({
    broker     => $broker,
    upload_url => request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'),
});

if (request()->param('whattodo') and request()->param('whattodo') eq 'process_superderivatives_correlations') {
    my $cgi          = CGI->new;
    my $filetoupload = $cgi->param('filetoupload');
    local $CGI::POST_MAX        = 1024 * 100 * 8;    # max 800K posts
    local $CGI::DISABLE_UPLOADS = 0;                 # enable uploads
    my ($data, @to_print) = upload_and_process_correlations($filetoupload);
    my $correlation_matrix = Quant::Framework::CorrelationMatrix->new({
        symbol           => 'indices',
        chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
        chronicle_write  => 1,
        recorded_date    => Date::Utility->new
    });
    $correlation_matrix->correlations($data);
    $correlation_matrix->save;
    print join "<p> ", @to_print;
}

code_exit_BO();
