
=head1 NAME

BOM::RPC::v3::Debug

=head1 DESCRIPTION

This is a package containing various debugging functions for bom-rpc. The RPCs
provided here should generally not be exposed to external clients via the
websocket API. They are intended for internal use only.

=cut

package BOM::RPC::v3::Debug;

use strict;
use warnings;

no indirect;

use IO::Async::Timer::Periodic;

use BOM::RPC::Registry '-dsl';

async_rpc sleep => sub {
    my $params = shift;

    my $seconds = $params->{seconds};

    # IO::Async::Loop->new is a singleton
    my $loop = IO::Async::Loop->new;

    if ($params->{verbose}) {
        my $f = $loop->new_future;
        $loop->add(
            IO::Async::Timer::Periodic->new(
                first_interval => 0,
                interval       => 1,
                on_tick        => sub {
                    my ($self) = shift;

                    if ($seconds > 0) {
                        print STDERR "[$$] Countdown; $seconds seconds remaining\n";
                        $seconds--;
                        return;
                    }

                    print STDERR "[$$] Countdown finished\n";
                    $self->remove_from_parent;
                    $f->done("success");
                }
            )->start
        );
        return $f;
    } else {
        return $loop->delay_future(after => $params->{seconds})->then_done("success");
    }
};

1;
