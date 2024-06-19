package BOM::MarketDataAutoUpdater::Script::ForexFactoryAlert;

use Moose;
with 'App::Base::Script';

use BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents;
use Digest::MD5 qw(md5_hex);
use ForexFactory;
use Email::Address::UseXS;
use Email::Stuffer;
use Date::Utility;
use Cache::RedisDB;
use Brands;

use constant {
    NAMESPACE => 'FOREX_FACTORY_ALERT',
    REDIS_KEY => 'RERUN_ECONOMIC_EVENT_UPDATE',
};

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
        my $body         = join "\n", map { $_->{event_name} . ' release at ' . Date::Utility->new($_->{release_date})->datetime } @alert;
        my $to           = Brands->new(name => 'deriv')->emails('quants');
        Email::Stuffer->from('system@binary.com')->to($to)->subject($subject_line)->text_body($body)->send_or_die;

        my $val       = md5_hex($body);
        my $cache_val = Cache::RedisDB->get(NAMESPACE, REDIS_KEY);
        # run the cron again to update
        if (not defined $cache_val or $cache_val ne $val) {
            Cache::RedisDB->set(NAMESPACE, REDIS_KEY, $val, 86400);
            BOM::MarketDataAutoUpdater::Script::UpdateEconomicEvents->new->run();
        }
    }

    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
