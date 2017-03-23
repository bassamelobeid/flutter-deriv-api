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
use Quant::Framework::EconomicEventCalendar;
use BOM::Platform::Chronicle;
use Try::Tiny;
BOM::Backoffice::Sysinit::init();
use BOM::Platform::Config;

PrintContentType();
BrokerPresentation("QUANT BACKOFFICE");

use Mail::Sender;
use ForexFactory;
use BOM::Platform::Config;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Backoffice::Request qw(request);
use Quant::Framework::CorrelationMatrix;
my $broker = request()->broker_code;
BOM::Backoffice::Auth0::can_access(['Quants']);

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

if (request()->param('whattodo') eq 'process_dividend') {
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

if (request()->param('whattodo') eq 'process_superderivatives_correlations') {
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

Bar("Update the news events database");

# Input fields
my $symbol                 = request()->param('symbol');
my $impact                 = request()->param('impact');
my $event_name             = request()->param('event_name');
my $release_date           = request()->param('release_date');
my $source                 = request()->param('source');
my $save_economic_event    = request()->param('save_economic_event');
my $is_tentative           = request()->param('is_tentative');
my $estimated_release_date = request()->param('estimated_release_date');

if ($save_economic_event) {
    try {
        my $ref         = BOM::Platform::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
        my @events      = @{$ref->{events}};
        my $event_param = {
            event_name => $event_name,
            source     => $source,
            impact     => $impact,
            symbol     => $symbol,
        };

        if ($is_tentative) {
            $event_param->{is_tentative} = $is_tentative;
            die 'Must specify estimated announcement date for tentative events' if (not $estimated_release_date);
            $event_param->{estimated_release_date} = Date::Utility->new($estimated_release_date)->truncate_to_day->epoch;
        } else {
            die 'Must specify announcement date for economic events' if (not $release_date);
            $event_param->{release_date} = Date::Utility->new($release_date)->epoch;
        }

        my $id_date = $release_date || $estimated_release_date;
        $event_param->{id} = ForexFactory::generate_id(Date::Utility->new($id_date)->truncate_to_day()->epoch . $event_name . $symbol . $impact);
        push @{$ref->{events}}, $event_param;
        Quant::Framework::EconomicEventCalendar->new({
                events           => $ref->{events},
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
            })->save;

        print 'Econmic Announcement saved!</br></br>';
        $save_economic_event = 0;
    }
    catch {

        print 'Error: ' . encode_entities($_);
    };
}

code_exit_BO();
