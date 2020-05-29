package BOM::Backoffice::EconomicEventTool;

use strict;
use warnings;

use Date::Utility;
use JSON::MaybeXS;
use List::Util qw(first);
use Quant::Framework::EconomicEventCalendar;
use Syntax::Keyword::Try;
use Volatility::Seasonality;
use LandingCompany::Registry;
use BOM::Config::Redis;

use BOM::Backoffice::Request;
use BOM::Backoffice::QuantsAuditLog;
use BOM::Backoffice::Cookie;
use BOM::MarketData qw(create_underlying_db create_underlying);
use BOM::Config::Chronicle;
use BOM::Config::Runtime;
use Quant::Framework::VolSurface::Delta;
use Quant::Framework;
use Finance::Exchange;
use Math::Business::BlackScholesMerton::NonBinaries;
my $json = JSON::MaybeXS->new;

sub get_economic_events_for_date {
    my $date = shift;

    return _err('Date is undefined') unless $date;
    $date = Date::Utility->new($date);

    my $eec             = _eec();
    my $from            = $date->truncate_to_day;
    my $to              = $from->plus_time_interval('23h59m59s');
    my $economic_events = $eec->get_latest_events_for_period({
        from => $from,
        to   => $to,
    });

    my @categorized_events = map { get_info($_) } grep { Volatility::EconomicEvents::is_defined($_->{symbol}, $_->{event_name}) } @$economic_events;
    my @uncategorized_events =
        map { get_info($_) } grep { !Volatility::EconomicEvents::is_defined($_->{symbol}, $_->{event_name}) } @$economic_events;
    my @deleted_events =
        map { get_info($_) }
        grep { Date::Utility->new($_->{release_date})->epoch >= $from->epoch && Date::Utility->new($_->{release_date})->epoch <= $to->epoch }
        (values %{$eec->_get_deleted()});
    my @l = _get_affected_underlying_symbols();
    return {
        categorized_events   => $json->encode(\@categorized_events),
        uncategorized_events => $json->encode(\@uncategorized_events),
        deleted_events       => $json->encode(\@deleted_events),
        underlying_symbols   => $json->encode([sort @l]),
    };
}

sub generate_economic_event_tool {
    my $url            = shift;
    my $disabled_write = shift;

    my $events = get_economic_events_for_date(Date::Utility->new);
    my $today  = Date::Utility->new->truncate_to_day;
    my @dates  = map { $today->plus_time_interval($_ . 'd')->date } (0 .. 14);

    return BOM::Backoffice::Request::template()->process(
        'backoffice/economic_event_forms.html.tt',
        +{
            ee_upload_url => $url,
            dates         => \@dates,
            %$events,
            disabled => $disabled_write,
        },
    ) || die BOM::Backoffice::Request::template()->error;
}

# get the calibration magnitude and duration factor of the given economic event, if any.
sub get_info {
    my $event = shift;

    $event->{release_date} = Date::Utility->new($event->{release_date})->datetime;
    $event->{not_categorized} = !Volatility::EconomicEvents::is_defined($event->{symbol}, $event->{event_name});
    foreach my $symbol (_get_affected_underlying_symbols()) {
        my ($ev) = @{Volatility::EconomicEvents::categorize_events($symbol, [$event])};
        next unless $ev;
        delete $ev->{release_epoch};
        unless ($ev->{vol_change_before}) { delete @{$ev}{qw/vol_change_before duration_before/} }
        $event->{info}->{$symbol} = $ev;
    }

    return $event;
}

sub delete_by_id {
    my $id    = shift;
    my $staff = shift;

    return _err("ID is not found.") unless ($id);

    my $eec = _eec();

    my $deleted = $eec->delete_event({
        id => $id,
    });

    return _err('Economic event not found with [' . $id . ']') unless $deleted;

    _regenerate($eec->get_all_events());

    BOM::Backoffice::QuantsAuditLog::log($staff, "deleteeconomicevent", "Event_name: " . $deleted->{event_name} . " id: $id");

    return get_info($deleted);
}

sub update_by_id {
    my $args = shift;

    return _err("ID is not found.")           unless $args->{id};
    return _err("underlying is not provided") unless $args->{underlying};

    my $ul = delete $args->{underlying};
    $args->{custom}->{$ul} =
        {map { my $v = delete $args->{$_}; $v ne '' ? ($_ => $_ =~ /vol/ ? $v / 100 : $_ =~ /duration/ ? $v * 60 : $v) : () }
            qw/vol_change duration vol_change_before duration_before decay_factor decay_factor_before/};

    return _err('Please specify at least one change') unless %{$args->{custom}};

    my $eec     = _eec();
    my $updated = $eec->update_event($args);

    return _err('Did not find event with id: ' . $args->{id}) unless $updated;

    _regenerate($eec->get_all_events());

    my $args_content = join(q{, }, map { qq{$_ => $args->{custom}->{$ul}->{$_}} } keys %{$args->{custom}->{$ul}});
    BOM::Backoffice::QuantsAuditLog::log($args->{staff}, "updateeconomicevent",
        "Event_name: " . $updated->{event_name} . " id: " . $args->{id} . " $args_content");

    return get_info($updated);
}

sub save_new_event {
    my $args  = shift;
    my $staff = shift;

    if (not $args->{release_date}) {
        return _err('Must specify announcement date for economic events');
    }
    try {
        $args->{release_date} = Date::Utility->new($args->{release_date})->epoch if $args->{release_date};
    }
    catch {
        return _err(split "\n", $@);    #handle Date::Utility's confess() call
    }

    my $eec   = _eec();
    my $added = $eec->add_event($args);

    return _err('Identical event exists. Economic event not saved') unless $added;

    _regenerate($eec->get_all_events());

    BOM::Backoffice::QuantsAuditLog::log($staff, "savedneweconomicevent", "Event_name: " . $added->{event_name});

    return get_info($added);
}

sub restore_by_id {
    my $id    = shift;
    my $staff = shift;

    my $eec = _eec();

    my $restored = $eec->restore_event($id);

    return _err('Failed to restore event.') unless $restored;

    BOM::Backoffice::QuantsAuditLog::log($staff, "restoredconomicevent", "Event_name: " . $restored->{event_name});

    _regenerate($eec->get_all_events());

    return get_info($restored);
}

sub _regenerate {
    my $events = shift;

    # signal pricer to refresh cache
    my $redis = BOM::Config::Redis::redis_replicated_write();
    $redis->set('economic_events_cache_snapshot', time);

    # update economic events impact curve with the newly added economic event
    Volatility::EconomicEvents::generate_variance({
        underlying_symbols => [_get_affected_underlying_symbols()],
        economic_events    => $events,
        chronicle_writer   => BOM::Config::Chronicle::get_chronicle_writer(),
    });

    return;
}

sub _err {
    return {error => 'ERR: ' . shift};
}

my @symbols;

sub _get_affected_underlying_symbols {
    return @symbols if @symbols;

    # default to svg since it does not matter
    my $offerings_obj = LandingCompany::Registry::get('svg')->basic_offerings(BOM::Config::Runtime->instance->get_offerings_config);
    @symbols = $offerings_obj->query({submarket => 'major_pairs'}, ['underlying_symbol']);
    return @symbols;
}

sub _eec {
    return Quant::Framework::EconomicEventCalendar->new(
        chronicle_reader => BOM::Config::Chronicle::get_chronicle_reader(),
        chronicle_writer => BOM::Config::Chronicle::get_chronicle_writer(),
    );
}

1;
