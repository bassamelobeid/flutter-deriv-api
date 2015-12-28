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
            $self->get_latest_events_for_period({
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
        push @event_objs, BOM::MarketData::EconomicEvent->new($ee_params);
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
