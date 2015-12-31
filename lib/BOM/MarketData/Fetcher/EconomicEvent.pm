package BOM::MarketData::Fetcher::EconomicEvent;

=head1 NAME

BOM::MarketData::Fetcher::EconomicEvent

=cut

=head1 DESCRIPTION

Responsible to fetch or create events on couchDB

=cut

use Carp;
use Moose;
#use BOM::Platform::Data::CouchDB;
use List::MoreUtils qw(notall);

use BOM::Platform::Runtime;
use BOM::MarketData::EconomicEvent;
use Sereal qw(encode_sereal decode_sereal looks_like_sereal);
use Sereal::Encoder;
use Try::Tiny;
use BOM::Utility::Log4perl qw(get_logger);
use BOM::System::Chronicle;
use BOM::MarketData::EconomicEventCouch;

has data_location => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    default  => sub { BOM::Platform::Runtime->instance->datasources->couchdb_databases->{economic_events}; },
);

has _couchdb => (
    is         => 'ro',
    isa        => 'BOM::Platform::Data::CouchDB',
    lazy_build => 1,
);

sub _build__couchdb {
    my $self = shift;
    return BOM::Platform::Runtime->instance->datasources->couchdb('economic_events');
}

has source => (
    is      => 'ro',
    isa     => 'Str',
    default => sub { BOM::Platform::Runtime->instance->app_config->quants->market_data->economic_announcements_source },
);

=head2 create_doc

Creates a couch doc with given data. On success, it returns the document id, false otherwise

    my $dm = BOM::MarketData::Fetcher::EconomicEvent->new;
    my $doc_id = $dm->create_doc($data);

=cut

sub create_doc {
    my ($self, $data) = @_;
    my $doc;

    my $doc_id;
    $self->_clear_event_cache;
    try {
        $doc_id = $self->_couchdb->create_document();
        $self->_couchdb->document($doc_id, $data);
    };

    BOM::MarketData::EconomicEvent->new($data)->save;

    return $doc_id;
}

=head2 retrieve_doc_with_view

Returns couch doc(s) object that matches the view params (symbol, release_date, event_name)

    my $dm   = BOM::MarketData::Fetcher::EconomicEvent->new();
    my @docs = $dm->retrieve_doc_with_view({
            symbol       => $symbol,
            release_date => $release_date,
            event_name   => $event_name
    });

=cut

sub retrieve_doc_with_view {
    my ($self, $args) = @_;

    my $symbol = $args->{symbol};
    my $release_date =
        (ref $args->{release_date} eq 'Date::Utility')
        ? $args->{release_date}->datetime_iso8601
        : Date::Utility->new($args->{release_date})->datetime_iso8601;
    my $event_name = $args->{event_name};

    my $query = {key => [$symbol, $release_date, $event_name]};

    my @docs;
    foreach my $doc_id (@{$self->_couchdb->view('existing_events', $query)}) {
        push @docs, $self->_couchdb->document($doc_id);
    }

    return @docs;
}

=head2 get_latest_events_for_period

Returns all events that will happen on a pre-specified period.

    my $eco = BOM::MarketData::Fetcher::EconomicEvent->new();
    my $events_for_tomorrow = $eco->get_latest_events_for_period({
            from => $start_period,
            to   => $end_period);

=cut

my $cache_namespace = 'COUCH_NEWS::';

sub get_latest_events_for_period {
    my ($self, $period, $debug) = @_;
    my $couch_result     = $self->_get_latest_events_for_period($period);
    my $chronicle_result = $self->_get_latest_events_for_period_chronicle($period);
    my $start            = $period->{from}->epoch;
    my $end              = $period->{to}->epoch;

    my $logger = get_logger();

    #if we are requested to operate in debug mode, then comapre and write output
    if (defined $debug and ($debug == 1 or $debug == 2)) {
        #now compare two resultsets
        print "Sizes do not match\n" if (scalar @$couch_result != scalar @$chronicle_result);
        print "couch size is " . scalar @$couch_result . "\n";
        print "chronicle size is " . scalar @$chronicle_result . "\n";
        print "couch data is " . Dumper($couch_result) . "\n"        if $debug == 2;
        print "chronicle data is" . Dumper($chronicle_result) . "\n" if $debug == 2;

        my $first = 1;
        for my $couch_event (@$couch_result) {
            #couch_event is of type EconomicEvent
            print "matching for couch $couch_event->{symbol} $couch_event->{event_name} $couch_event->{release_date} \n" if $first;
            my $has_a_match = 0;
            for my $chr_event (@$chronicle_result) {
                print "matching with $chr_event->{symbol} $chr_event->{event_name} $chr_event->{release_date} \n" if $first;
                #chr_event is of type EconomicEventChronicle
                if (   $couch_event->{release_date}->epoch == $chr_event->{release_date}->epoch
                    && $couch_event->{symbol} eq $chr_event->{symbol}
                    && $couch_event->{event_name} eq $chr_event->{event_name})
                {
                    $has_a_match = 1;
                    print "Found a match!\n";
                    last;
                }

            }
            $first = 0;
            print ">>>>>>>>>>>>>>>>>>>> couch event <" . $couch_event->{event_name} . "> does not have a match\n" if !$has_a_match;
        }
    }
    return $chronicle_result;
}

sub _get_latest_events_for_period_chronicle {
    my ($self, $period) = @_;
    my $chronicle_result = [];
    my $logger           = get_logger();

    try {
        my $start  = $period->{from}->epoch;
        my $end    = $period->{to}->epoch;
        my $source = $period->{source} ? $period->{source} : $self->{source};

        #try to read from Chronicle (in-memory data)
        my $extracted_events = BOM::System::Chronicle::get('economic_events', 'economic_events');

        #what is the period of the release dates of current economic events we have?
        my $current_start = Date::Utility->new($extracted_events->[0]->{release_date})->epoch;
        #my $current_end   = $extracted_events->[-1]->{release_date}->epoch;

        use Data::Dumper;
        #in case we do not have enough economic events to cover the requested time period, add from Chronicle's DB
        if ($start < $current_start) {
            #each element in this array-ref is an array of economic events
            my $db_events = BOM::System::Chronicle::get_for_period('economic_events', 'economic_events', $start, $end);

            #combine in-memory event with those from database
            for my $db_event (@$db_events) {
                push $extracted_events, $_ for @$db_event;
            }
        }

        #now filter events that fall in the range we are looking for
        my %matching_events;

        for my $single_ee (@$extracted_events) {
            my $ee_epoch = Date::Utility->new($single_ee->{release_date})->epoch;

            $single_ee->{symbol}       //= "";
            $single_ee->{release_date} //= "";
            $single_ee->{event_name}   //= "";

            #prevent adding repeated economic events by storing in a hash based on a uniqe key
            my $unique_key = $single_ee->{symbol} . $single_ee->{release_date} . $single_ee->{event_name};

            if ($ee_epoch >= $start and $ee_epoch <= $end) {
                $matching_events{$unique_key} = BOM::MarketData::EconomicEvent->new($single_ee);
            }
        }

        my @matching_events_values = values %matching_events;
        @matching_events_values = sort { $a->release_date->epoch <=> $b->release_date->epoch } @matching_events_values;
        $chronicle_result = \@matching_events_values;
    }
    catch {
        $logger->warn("Error getting chronicle results: " . $_);
    };

    return $chronicle_result;
}

sub _get_latest_events_for_period {
    my ($self, $period) = @_;

    # We may do this from time to time.
    # I claim it's under control.
    ## no critic(TestingAndDebugging::ProhibitNoWarnings)
    no warnings 'recursion';

    my $events = [];
    my $start  = $period->{from};
    my $end    = $period->{to};
    my $source = $period->{source} ? $period->{source} : $self->{source};

    # Guard against mal-formed queries.
    return $events if ($end->is_before($start));

    if ($start->days_since_epoch == $end->days_since_epoch) {
        # A single (partial?) day. We can do a simple request.
        $period->{source} //= $source;
        $events = $self->_latest_events_for_day_part($period);
    } else {
        # More than a day.  We need to chop it up.
        # Since we keep shifting days off the front, the above will notice when we might go past the end of day.
        my $end_of_first  = $start->truncate_to_day->plus_time_interval('23h59m59s');
        my $start_of_next = $end_of_first->plus_time_interval('1s');
        push @$events,
            @{
            $self->_latest_events_for_day_part({
                    from   => $start,
                    to     => $end_of_first,
                    source => $source
                })};
        push @$events,
            @{
            $self->_get_latest_events_for_period({
                    from   => $start_of_next,
                    to     => $end,
                    source => $source
                })};
    }

    return $events;
}

sub _latest_events_for_day_part {
    my ($self, $period) = @_;

    my $events    = [];
    my $start     = $period->{from};
    my $end       = $period->{to};
    my $source    = $period->{source};
    my $day       = $start->truncate_to_day;
    my $redis     = $self->_redis;
    my $cache_key = $cache_namespace . $day->date . '_' . $source;

    if ($redis->exists($cache_key)) {
        my $docs = $redis->zrangebyscore($cache_key, $start->epoch, $end->epoch);
        foreach my $data (@{$docs}) {
            push @$events, decode_sereal($data) if looks_like_sereal($data);
        }
    } else {
        my $whole_day = {
            view   => 'by_release_date',
            from   => $day,
            to     => $day->plus_time_interval('23h59m59s'),    # Do not put 0000UTC events in two days.
            source => $source,
        };

        $events = $self->_get_events($whole_day);
        if (not scalar @$events) {
            $redis->zadd($cache_key, 0, 'fake_doc_id');         # Make sure the key comes into existence.
        } else {
            foreach my $event (@$events) {
                $redis->zadd($cache_key, $event->release_date->epoch, Sereal::Encoder->new({protocol_version => 2})->encode($event));
            }
        }
        $redis->expire($cache_key, 613);
        # Should hit the cache this time through
        $events = $self->_latest_events_for_day_part($period);
    }

    return $events;
}

sub _redis {
    return Cache::RedisDB->redis;
}

sub _get_events {
    my ($self, $args) = @_;

    croak 'start date undef during economic events calculation'
        unless defined $args->{from};
    croak 'end date undef during economic events calculation'
        unless defined $args->{to};

    my ($start, $end) = map { Date::Utility->new($_) } @{$args}{'from', 'to'};
    my $source = $args->{source};
    # Here we just fill the cache then send them back to get it from there.
    my $query = {
        startkey => [$source, $start->datetime_iso8601],
        endkey   => [$source, $end->datetime_iso8601],
    };

    my $docs = $self->_couchdb->view($args->{view}, $query);

    my @event_objs;
    foreach my $data (@{$docs}) {
        my $ee_params = $self->_couchdb->document($data);
        $ee_params->{document_id} //= $data;
        push @event_objs, BOM::MarketData::EconomicEventCouch->new($ee_params);
    }

    return \@event_objs;
}

sub _clear_event_cache {
    my $self = shift;

    my $redis = $self->_redis;

    # Don't bother trying to figure out which events they are adding.
    # Just assume that everything is wrong.
    my @results = map { $redis->del($_) } @{$redis->keys($cache_namespace . '*')};

    return scalar @results;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
