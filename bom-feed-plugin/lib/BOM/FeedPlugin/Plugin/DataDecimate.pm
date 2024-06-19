package BOM::FeedPlugin::Plugin::DataDecimate;

use strict;
use warnings;

=head1 NAME

BOM::FeedPlugin::Plugin::DataDecimate

=head1 SYNOPSIS

    use BOM::FeedPlugin::Plugin::DataDecimate

=head1 DESCRIPTION

This package is used as a plugin by L<BOM::FeedPlugin::Client> where it will be called if it was added to the array of plugins in Client.

=head1 REQUIRED METHODS

The plugin requires symbol market I<market> method.

=cut

use Moo;
use namespace::autoclean;
use BOM::MarketData::Types;
use BOM::MarketData qw(create_underlying_db);
use BOM::Config;
use BOM::Config::Runtime;
use BOM::Config::Redis;
use DataDog::DogStatsd::Helper qw(stats_inc stats_timing);
use Time::HiRes;
use List::Util     qw(max);
use Data::Decimate qw(decimate);
use BOM::Market::DataDecimate;
use Finance::Underlying;
use Postgres::FeedDB;
use Postgres::FeedDB::Spot::DatabaseAPI;

has market => (
    is       => 'ro',
    required => 1
);
has _symbols_to_decimate => (
    is => 'lazy',
);

sub _build__symbols_to_decimate {
    my $self = shift;
    my @symbols =
        $self->market eq 'forex'             ? create_underlying_db->symbols_for_intraday_fx(1)
        : $self->market eq 'synthetic_index' ? create_underlying_db->get_symbols_for(
        market            => 'synthetic_index',
        contract_category => 'lookback'
        )
        : die 'Unexpected market';
    return {map { $_ => Finance::Underlying->by_symbol($_) } @symbols};
}

has _tick_source => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build__tick_source',
);

sub _build__tick_source {
    my $self = shift;

    return BOM::Market::DataDecimate->new({
        market                 => $self->market,
        redis_write            => BOM::Config::Redis::redis_feed_master_write(),
        redis_read             => BOM::Config::Redis::redis_feed_replica(),
        raw_retention_interval => Time::Duration::Concise->new(interval => '31m'),
    });
}

has _last_updated_timestamp => (
    is      => 'ro',
    default => sub { {} },
);

sub BUILD {
    my $self           = shift;
    my $decimate_cache = $self->_tick_source;
    #back populate
    my $end   = time;
    my $start = $end - $decimate_cache->raw_retention_interval->seconds;
    foreach my $symbol (keys %{$self->_symbols_to_decimate}) {
        my $last_raw_tick      = $decimate_cache->get_latest_tick_epoch($symbol, 0, $start, $end);
        my $last_raw_epoch     = max($start, $last_raw_tick + 1);
        my $last_updated_epoch = $self->_refill_from_db($decimate_cache, $symbol, $last_raw_epoch, $end);
        $self->_last_updated_timestamp->{$symbol} = $last_updated_epoch // $last_raw_tick;
    }
    return;
}

sub _refill_from_db {
    my ($self, $decimator, $symbol, $from, $to, $refill_ontick) = @_;

    return if $from > $to;

    my $feed_api = Postgres::FeedDB::Spot::DatabaseAPI->new({
        underlying => $symbol,
        dbic       => Postgres::FeedDB::read_dbic,
    });
    my $ticks = $feed_api->ticks_start_end({
        start_time => $from,
        end_time   => $to,
    });

    # notify when historical populate delay happens
    stats_inc("feed.client.plugin.datadecimate.delayed_start")
        if @$ticks and $refill_ontick;

    $decimator->data_cache_back_populate_raw($symbol, $ticks);

    return $ticks->[0]->{epoch};
}

=head2 $self->on_tick($tick)

The main method which it will receive a tick and then update DataDecimate object with the latest tick, and update DD stats.

=cut

sub on_tick {
    my ($self, $tick) = @_;
    my $market = $self->market;
    my $symbol = $tick->{symbol};
    if ($self->_symbols_to_decimate->{$symbol}) {
        # Source is not needed here and it will corrupt Decimate output if kept.
        delete $tick->{source};
        # At this moment, this tick should be available to the clients that are using it.
        # Log the latency here.
        my $ts = Time::HiRes::time;

        # On service restart, if BUILD takes too long to execute, we could have missing tick.
        # This repopulation will refill the missing ticks on the first incoming message.
        if ($self->_last_updated_timestamp->{$symbol} > 0) {
            $self->_refill_from_db($self->_tick_source, $symbol, $self->_last_updated_timestamp->{$symbol} + 1, $tick->{epoch} - 1, 'refill_ontick');
            $self->_last_updated_timestamp->{$symbol} = 0;
        }

        $self->_tick_source->data_cache_insert_raw($tick);
        # update statistics about number of processed ticks (once in 10 ticks)
        my $basename = "feed.client.plugin.datadecimate-$market";
        my $latency  = $ts - $tick->{epoch};
        my $tags     = {tags => ['symbol:' . $tick->{symbol}, 'seconds:' . int($latency)]};

        stats_timing("$basename.latency", 1000 * $latency, $tags);
    }
    return;
}

1;
