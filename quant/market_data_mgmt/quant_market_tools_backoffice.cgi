#!/usr/bin/perl
package main;
use strict 'vars';

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use SuperDerivatives::Correlation qw( upload_and_process_correlations );
use subs::subs_dividend_from_excel_file;
use BOM::Platform::Sysinit ();
use Quant::Framework::EconomicEventCalendar;
use BOM::System::Chronicle;
use Try::Tiny;
BOM::Platform::Sysinit::init();

PrintContentType();
BrokerPresentation("QUANT BACKOFFICE");

use Mail::Sender;
use ForexFactory;
use BOM::System::Localhost;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Utility::Log4perl qw( get_logger );
use BOM::Platform::Context;
use BOM::MarketData::CorrelationMatrix;
my $broker = request()->broker->code;
BOM::Backoffice::Auth0::can_access(['Quants']);

if ($broker !~ /^\w+$/) { die "Bad broker code $broker in $0"; }

unless (BOM::System::Localhost::is_master_server()) {
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
    my $cgi                      = new CGI;
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
    my $cgi          = new CGI;
    my $filetoupload = $cgi->param('filetoupload');
    local $CGI::POST_MAX        = 1024 * 100 * 8;    # max 800K posts
    local $CGI::DISABLE_UPLOADS = 0;                 # enable uploads
    my ($data, @to_print) = upload_and_process_correlations($filetoupload);
    my $correlation_matrix = BOM::MarketData::CorrelationMatrix->new({
        symbol        => 'indices',
        recorded_date => Date::Utility->new
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
my $add_news_event         = request()->param('add_news_event');
my $save_economic_event    = request()->param('save_economic_event');
my $autoupdate             = request()->param('autoupdate');
my $is_tentative           = request()->param('is_tentative');
my $estimated_release_date = request()->param('estimated_release_date');

if ($autoupdate) {
    eval { print "Not implemented yet"; };
    if (my $error = $@) {
        my $msg    = 'Error while fetching economic events on date [' . Date::Utility->new->datetime . ']';
        my $sender = Mail::Sender->new({
            smtp    => 'localhost',
            from    => 'Market tools <market-tools@binary.com>',
            to      => 'Quants <x-quants-alert@binary.com>',
            subject => $msg,
        });
        $sender->MailMsg({msg => $msg});

        print "Error while updating news calendar: $error";
        get_logger->error("Error while updating news calendar: $error");
    }
} elsif ($save_economic_event) {
    try {
        my $ref         = BOM::System::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
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
                chronicle_reader => BOM::System::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::System::Chronicle::get_chronicle_writer(),
            })->save;

        print 'Econmic Announcement saved!</br></br>';
        $save_economic_event = 0;
    }
    catch {

        print 'Error: ' . $_;
    };
}

code_exit_BO();
