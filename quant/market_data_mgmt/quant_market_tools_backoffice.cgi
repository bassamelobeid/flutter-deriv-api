#!/usr/bin/perl
package main;
use strict 'vars';

use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/bom/cgi/oop);
use f_brokerincludeall;
use BOM::Platform::Plack qw( PrintContentType );
use BOM::Market::DataSource::SuperDerivatives::Correlations qw( generate_correlations_upload_form upload_and_process_correlations );
use subs::subs_dividend_from_excel_file;
system_initialize();

PrintContentType();
BrokerPresentation("QUANT BACKOFFICE");

use Mail::Sender;
use BOM::MarketData::Parser::ForexFactoryEconomicEvent;
use BOM::MarketData::Display::EconomicEvent;
use BOM::MarketData::EconomicEvent;
use BOM::Platform::Runtime;
use BOM::Utility::Date;
use BOM::MarketData::Fetcher::EconomicEvent;
use BOM::MarketData::Parser::Bloomberg::EconomicEvent;
use BOM::Utility::Log4perl qw( get_logger );

my $broker = request()->broker->code;
BOM::Platform::Auth0::can_access(['Quants']);

if ($broker !~ /^\w+$/) { die "Bad broker code $broker in $0"; }

# Exit when not master live server (or not development pc)
if (BOM::Platform::Runtime->instance->hosts->localhost->canonical_name ne MasterLiveServer()) {
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
    print upload_and_process_correlations($filetoupload);
}

Bar("Update the news events database");

# Input fields
my $symbol                    = request()->param('symbol');
my $impact                    = request()->param('impact');
my $event_name                = request()->param('event_name');
my $release_date              = request()->param('release_date');
my $source                    = request()->param('source');
my $add_news_event            = request()->param('add_news_event');
my $remove_news_id            = request()->param('remove_news_id');
my $save_economic_event       = request()->param('save_economic_event');
my $autoupdate                = request()->param('autoupdate');
my $bloomberg_economic_events = request()->param('process_bloomberg_economic_events');
my $display                   = BOM::MarketData::Display::EconomicEvent->new;

# Manual cron runner for economic events
print $display->economic_event_forms(request()->url_for('backoffice/quant/market_data_mgmt/quant_market_tools_backoffice.cgi'));

if ($autoupdate) {
    eval {
        my $num_of_events_updated = BOM::MarketData::Parser::ForexFactoryEconomicEvent->new()->update_economic_events;
        print $num_of_events_updated . ' economic events were successfully saved on couch.</br></br>';
    };
    if (my $error = $@) {
        my $msg    = 'Error while fetching economic events on date [' . BOM::Utility::Date->new->datetime . ']';
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
    eval { BOM::Utility::Date->new($release_date); };

    if ($@) {
        print 'The economic event was not saved. Please enter a valid date (2012-11-19T23:00:00Z)</br></br>';
    } else {
        my $event_param = {
            event_name   => $event_name,
            source       => $source,
            release_date => $release_date,
            impact       => $impact,
            symbol       => $symbol,
        };
        my $event = BOM::MarketData::EconomicEvent->new($event_param);
        $event->save;
        print 'Econmic Announcement saved!</br></br>';
        $save_economic_event = 0;
    }
} elsif ($remove_news_id) {
    my $dm = BOM::MarketData::Fetcher::EconomicEvent->new();
    eval {
        my @docs = $dm->retrieve_doc_with_view({
                symbol       => $symbol,
                event_name   => $event_name,
                release_date => $release_date
        });
        my $doc_num = scalar @docs;
        if ($doc_num) {
            my @deleted = map { $_->delete } @docs;
            print scalar @deleted . ' document(s) deleted</br></br>';
        } else {
            print 'No document found</br></br>';
        }
    };

    if (my $error = $@) {
        print "Document deletion error: $error";
        get_logger->error($error);
    }
    $remove_news_id = 0;
} elsif ($bloomberg_economic_events) {

    my $cgi = new CGI;
    my $economic_event_saved;
    my $file   = $cgi->param('bloomberg_eco_file');
    my $now    = BOM::Utility::Date->new;
    my $parser = BOM::MarketData::Parser::Bloomberg::EconomicEvent->new;
    my $dm     = BOM::MarketData::Fetcher::EconomicEvent->new;
    eval { $parser->process_economic_events($now, $file); };

    if (my $error = $@) {
        print "Document deletion error: $error";
        get_logger->error($error);
    }

}

# Display economic events calendar
my $today = BOM::Utility::Date->new;
print '<b>The table below shows the economic events that will take place today (' . $today->date_ddmmmyyyy . ')</b></br></br>';
print $display->events_for_today;

print '</br></br>';

print '<b>The table below shows the economic events saved on couch today (' . $today->date_ddmmmyyyy . ')</b></br></br>';
print $display->all_events_saved_for_date($today);

code_exit_BO();
