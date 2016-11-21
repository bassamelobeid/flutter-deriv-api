#!/etc/rmg/bin/perl -w
package BOM::Product::HighLowWindow;

use Moose;
with 'App::Base::Daemon';

use BOM::Product::Contract::PredefinedParameters qw(update_predefined_highlow);

use JSON;

sub documentation {
    return qq/Update high and low of symbols for predefined periods./;
}

sub daemon_run {
    my $self = shift;

    my @symbols = BOM::Product::Contract::PredefinedParameters::supported_symbols;

    my $redis = BOM::System::RedisReplicated::redis_read();

    $redis->subscription_loop(
        subscribe        => [map { 'FEED::' . $_ } @symbols],
        default_callback => sub {
            my $tick_data = from_json($_[3]);
            update_predefined_highlow($tick_data);
        },
    );

    $self->_daemon_run;
}

sub handle_shutdown {
    my $self = shift;
    warn('Shutting down');
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Product::HighLowWindow->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;
