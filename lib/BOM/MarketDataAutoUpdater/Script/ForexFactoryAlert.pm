package BOM::MarketDataAutoUpdater::Script::ForexFactoryAlert;

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents;
use Quant::Framework::EconomicEventCalendar;
use ForexFactory;
use Email::Stuffer;
use Date::Utility;
use Cache::RedisDB;

use constant NAMESPACE => 'FOREX_FACTORY_ALERT';

sub documentation { return 'This script checks for forex factory alert on economic events every hour.'; }

sub script_run {
    my $self = shift;

    my $now    = Date::Utility->new;
    my $parser = ForexFactory->new();

    #read economic events for one week (7-days) starting from 4 days back, so in case of a Monday which
    #has its last Friday as a holiday, we will still have some events in the cache.
    my $events_received = $parser->extract_economic_events(2, Date::Utility->new()->minus_time_interval('4d'));

    # get all the events happening today
    if (
        my @alert = grep {
                   defined $_->{release_date}
                && $_->{release_date} >= $now->truncate_to_day->epoch
                && $_->{release_date} <= $now->plus_time_interval('1d')->truncate_to_day->epoch
                && $_->{forex_factory_alert}
                && $now->epoch < $_->{release_date}
        } @$events_received
        )
    {
        my $subject_line = 'Forex Factory Alert';
        my $body = join "\n", map { $_->{event_name} . ' release at ' . Date::Utility->new($_->{release_date})->datetime } @alert;
        Email::Stuffer->from('system@binary.com')->to('x-quants@binary.com')->subject($subject_line)->text_body($body)->send_or_die;

        my $counter = 0;
        for (@alert) {
            my $key = Quant::Framework::EconomicEventCalendar::generate_id($_);
            my $cache = Cache::RedisDB->get(NAMESPACE, $key);
            unless ($cache) {
                Cache::RedisDB->set(NAMESPACE, $key, 1, 86400);
                $counter++;
            }
        }
        # run the cron again to update
        BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents->new->run() if $counter > 0;
    }

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
