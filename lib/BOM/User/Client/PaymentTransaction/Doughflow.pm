package BOM::User::Client::PaymentTransaction::Doughflow;

use strict;
use warnings;

use Moo;

use BOM::User::Client::PaymentTransaction;

use namespace::clean;

=head1 NAME

 BOM::User::Client::PaymentTransaction::Doughflow - A class that stores a Doughflow payment transaction.
 Any object of the class represents a transaction created by a doughflow payment action.
 It is a subclass of L<BOM::User::Client::PaymentTransaction>.


=head1 SYNOPSIS

    my $txn = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT from payment.add_doughflow_payment(...)", ...);
        });

    return BOM::User::Client::PaymentTransaction::Doughflow->new(%$txn);

=head1 DESCRIPTION

This module is an object oriented wrapper around the output of 
C<payment.add_doughflow_payment> function, representing a payment transaction just created.

=cut

extends 'BOM::User::Client::PaymentTransaction';

has fee_payment_id => (
    is => 'ro',
);

has fee_transaction_id => (
    is => 'ro',
);

1;
