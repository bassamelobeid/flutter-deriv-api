package BOM::MarketData::EconomicEventCouch;

=head1 NAME

BOM::MarketData::EconomicEventCouch

=head1 DESCRIPTION

Represents an economic event in the financial market

    my $eco = BOM::MarketData::EconomicEvent->new({
        symbol => $symbol,
        release_date => $rd,
        impact => $impact,
        event_name => $event_name,
        source => $source, # currently just from forexfactory
        recorded_date => $rdate,
    });

=cut

use Moose;
extends 'BOM::MarketData';

use Cache::RedisDB;
use Date::Utility;
use List::Util qw(first);
use YAML::CacheLoader qw(LoadFile);

use BOM::Market::Types;
use BOM::MarketData::Fetcher::EconomicEvent;

has _data_location => (
    is      => 'ro',
    default => 'economic_events',
);

with 'BOM::MarketData::Role::VersionedSymbolData';

around _document_content => sub {
    my $orig = shift;
    my $self = shift;

    my $data = {
        %{$self->$orig},
        event_name   => $self->event_name,
        release_date => $self->release_date->datetime_iso8601,
        impact       => $self->impact,
        source       => $self->source,
    };
    $data->{eco_symbol} = $self->eco_symbol if $self->eco_symbol;

    return $data;
};

has eco_symbol => (
    is  => 'rw',
    isa => 'Maybe[Str]',
);

=head2 release_date
Date of which the economic event will take place
=cut

has release_date => (
    is       => 'ro',
    isa      => 'bom_date_object',
    coerce   => 1,
    required => 1,
);

=head2 impact
The impact of the economic event in the scale of 1-5.
5 = highest impact. 1 = lowest impact.
=cut

has impact => (
    is      => 'ro',
    isa     => 'Num',
    default => 5,
);

=head2 source
Source of economic events.
=cut

has source => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

=head2 event_name
The name of the economic announcement.
=cut

has event_name => (
    is      => 'ro',
    isa     => 'Str',
    default => 'Not Given',
);

sub _clear_cache {
    my $redis = Cache::RedisDB->redis;
    my @results = map { $redis->del($_) } @{$redis->keys('COUCH_NEWS::' . '*')};
    return @results;
}

# Update if document exist.
around save => sub {
    my $orig = shift;
    my $self = shift;

    if (my $identical_doc = $self->has_identical_event) {
        $identical_doc->{recorded_date} = Date::Utility->new->datetime_iso8601;
        $self->_clear_cache;
        return $self->_couchdb->document($identical_doc->{_id}, $identical_doc);
    } else {
        return $self->$orig;
    }
};

sub has_identical_event {
    my $self = shift;

    my @docs = BOM::MarketData::Fetcher::EconomicEvent->new->retrieve_doc_with_view({
        symbol       => $self->symbol,
        release_date => $self->release_date->datetime_iso8601,
        event_name   => $self->event_name
    });

    return (@docs) ? $docs[0] : '';
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
