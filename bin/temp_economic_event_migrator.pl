use Data::Dumper;
use BOM::MarketData::Fetcher::EconomicEvent;
use BOM::System::Chronicle;

my $start = Date::Utility->new('2014-06-01');
my $end = Date::Utility->new('2016-06-01');

my $events =
BOM::MarketData::Fetcher::EconomicEvent->new()->get_latest_events_for_period({
        from => $start,
        to=>    $end,
        }
    )
;

my $i=0;
foreach my $e (@$events) {
    $i++;
    my @a = qw(source event_name symbol release_date impact);
    my %s = map {$_ => $e->{$_}} @a;

    $s{release_date} = $s{release_date}->epoch;
    if ($e->{recorded_date}) {
        $s{recorded_date} = $e->{recorded_date}->epoch;
    } else {
        $s{recorded_date} = '1262304000'; # Old for sorting
    }
    BOM::System::Chronicle->_redis_write->zadd('ECONOMIC_EVENTS' , $s{release_date}, JSON::to_json(\%s));
}
print "[$i]\n";


my $original_event = BOM::MarketData::Fetcher::EconomicEvent->new()->get_latest_events_for_period({
    from => $start,
    to   => $end,
});

my $new_events;
my $docs = BOM::System::Chronicle->_redis_read->zrangebyscore('ECONOMIC_EVENTS', $start->epoch, $end->epoch);
foreach my $data (@{$docs}) {
   push @$new_events, BOM::MarketData::EconomicEvent->new(JSON::from_json($data));
}

foreach my $a (@$original_event) {
    my $b=0;
    foreach $c (@$new_events) {
        if (
            $a->release_date->epoch eq $c->release_date->epoch and
            $a->impact eq $c->impact and
            $a->symbol eq $c->symbol and
            $a->event_name eq $c->event_name
            ) {
            $b++;
        }
    }
    if (not $b) {
        print Data::Dumper::Dumper($a);
    }
}
