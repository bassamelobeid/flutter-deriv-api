package BOM::FeedPlugin::Plugin::FakeEmitter;

use strict;
use warnings;

use BOM::Config::Redis;
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;

=head1 NAME
BOM::FeedPlugin::Plugin::FakeEmitter
=head1 SYNOPSIS
use BOM::FeedPlugin::Plugin::FakeEmitter
=head1 DESCRIPTION
 This package is used as a plugin by L<BOM::FeedPlugin::Client> where it will be called if it was added to the array of plugins in Client.
 Its used to re-emmit ticks published in production, to QA environment.
 Taking production Distributor ticks and publish them for QAs where fake listeners will subscribe it, feeding those ticks to QA.
 publish B<TICK_ENGINE::$symbol> redis key.
=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 $self->on_tick($tick)
The main method which it will receive a tick and then update Redis with the latest tick.
=cut

sub on_tick {
    my ($self, $tick) = @_;

    # We added price parameter here in order to prevent QA from recalculating price.
    $tick->{price} = $tick->{quote};
    my $redis = BOM::Config::Redis::redis_feed_master_write();
    try {
        $redis->publish("TICK_ENGINE::" . $tick->{symbol}, encode_json_utf8($tick));
    } catch ($e) {
        use Data::Dumper;
        warn("Cannot save tick in redis at ::" . Dumper($e));
    }

    return;
}

1;

