#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use open qw[ :encoding(UTF-8) ];
use lib qw(/home/git/regentmarkets/bom-backoffice /home/git/regentmarkets/bom/cgi/oop);

use JSON qw(to_json);
use Volatility::Seasonality;
use Quant::Framework::EconomicEventCalendar;
use BOM::Platform::Chronicle;
use BOM::Backoffice::Sysinit ();
use BOM::EconomicEventTool;
BOM::Backoffice::Sysinit::init();

## Delete economic event

my $delete_event = request()->param('delete_event');
my $event_id     = request()->param('event_id');

if ($delete_event) {
    print to_json(BOM::EconomicEventTool::delete_by_id($event_id));
}

my $save_event = request()->param('save_event');

if ($save_event) {
    my $param = {
        symbol           => request()->param('symbol'),
        impact           => request()->param('impact'),
        event_name       => request()->param('event_name'),
        source           => request()->param('source'),
        custom_magnitude => (request()->param('custom_magnitude') // 0),
    };

    my $is_tentative = request()->param('is_tentative');
    my $err;
    if ($is_tentative) {
        $param->{is_tentative} = $is_tentative;
        my $erd = request()->param('estimated_release_date');
        if ($erd) {
            $param->{estimated_release_date} = Date::Utility->new($erd)->truncate_to_day->epoch;
        } else {
            $err = 'Must specify estimated announcement date for tentative events';
        }
    } else {
        my $rd = request()->param('release_date');
        if ($rd) {
            $param->{release_date} = Date::Utility->new($rd)->epoch;
        } else {
            $err = 'Must specify announcement date for economic events';
        }
    }

    my $ref          = BOM::Platform::Chronicle::get_chronicle_reader()->get('economic_events', 'economic_events');
    my @events       = @{$ref->{events}};
    my $new_event_id = Quant::Framework::EconomicEventCalendar::_generate_id($param);
    my $duplicate    = grep { $_->{id} eq $new_event_id } @events;

    if ($duplicate) {
        $err = 'Identical event exists. Economic event not saved';
    } else {
        push @{$ref->{events}}, $param;
        Quant::Framework::EconomicEventCalendar->new({
                events           => $ref->{events},
                recorded_date    => Date::Utility->new,
                chronicle_reader => BOM::Platform::Chronicle::get_chronicle_reader(),
                chronicle_writer => BOM::Platform::Chronicle::get_chronicle_writer(),
            })->save;

        # update economic events impact curve with the newly added economic event
        Volatility::Seasonality::generate_economic_event_seasonality({
            underlying_symbols => [create_underlying_db->symbols_for_intraday_fx],
            economic_events    => $ref->{events},
            chronicle_writer   => BOM::Platform::Chronicle::get_chronicle_writer(),
        });

        # refresh intradayfx cache to to use new economic events impact curve
        BOM::MarketDataAutoUpdater::Forex->new()->warmup_intradayfx_cache();
    }

    print($err ? to_json({error => $err}) : to_json(BOM::EconomicEventTool::get_info($param)));
}
