#!/usr/bin/perl -w

package BOM::Expiryd;

use Moose;
with 'App::Base::Daemon';
with 'BOM::Utility::Logging';

use ExpiryQueue qw( dequeue_expired_contract );
use Try::Tiny;

use BOM::Platform::Client;
use BOM::Product::Transaction;

sub documentation {
    return qq/This daemon sells off expired contracts in soft real-time./;
}

sub daemon_run {
    my $self = shift;

    $self->warn('Restarting.');
    while (1) {
        # Outer `while` to live through possible redis disconnects/restarts
        while (my $info = dequeue_expired_contract(1)) {    # Blocking for next available.
            try {
                my $contract_id = $info->{contract_id};
                my $client = BOM::Platform::Client->new({loginid => $info->{held_by}});
                if ($info->{in_currency} ne $client->currency) {
                    $self->warn('Skip on currency mismatch for contract '
                            . $contract_id
                            . '. Expected: '
                            . $info->{in_currency}
                            . ' Client uses: '
                            . $client->currency);
                    next;
                }
                # This returns a result which might be useful for reporting
                # but for now we will ignore it.
                BOM::Product::Transaction::sell_expired_contracts({
                        client       => $client,
                        source       => 1063,            # Third party application 'binaryexpiryd'
                        contract_ids => [$contract_id]});
            };    # No catch, let MtM pick up the pieces.
        }
    }
}

sub handle_shutdown {
    my $self = shift;
    $self->warn('Shutting down.');
    return 0;
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit BOM::Expiryd->new({
        user  => 'nobody',
        group => 'nogroup',
    })->run;
