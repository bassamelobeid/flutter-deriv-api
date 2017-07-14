package BOM::MarketDataAutoUpdater::Script::ForexFactoryAlert;

use Moose;
with 'App::Base::Script';

use ForexFactory;
use Email::Stuffer;
use Date::Utility;

sub documentation { return 'This script checks for forex factory alert on economic events every hour.'; }

sub script_run {
    my $self = shift;

    my $parser = ForexFactory->new();

    #read economic events for one week (7-days) starting from 4 days back, so in case of a Monday which
    #has its last Friday as a holiday, we will still have some events in the cache.
    my $events_received = $parser->extract_economic_events(2, Date::Utility->new()->minus_time_interval('4d'));

    # get all the events happening today
    if (
        my @alert = grep {
                   $_->{release_date} >= $now->truncate_to_day->epoch
                && $_->{release_date} <= $now->plus_time_interval('1d')->truncate_to_day->epoch
                && $_->{forex_factory_alert}
        } @$events_received
        )
    {
        my $subject_line = 'Forex Factory Alert';
        my $body = join "\n", map { $_->{event_name} . ' release at ' . Date::Utility->new($_->{release_date})->datetime } @alert;
        Email::Stuffer->from('system@binary.com')->to('quants-market-data@binary.com')->subject($subject_line)->text_body($body)->send_or_die;
    }

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
