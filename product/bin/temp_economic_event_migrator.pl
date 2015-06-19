use Data::Dumper;
use BOM::MarketData::Fetcher::EconomicEvent;
use BOM::System::Chronicle;

my $events =
BOM::MarketData::Fetcher::EconomicEvent->new()->get_latest_events_for_period({
		from => Date::Utility->new("2013-06-01"),
		to=>    Date::Utility->new("2016-06-01"),
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
