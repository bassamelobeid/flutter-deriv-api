package BOM::User::Client::PaymentTransaction;

use strict;
use warnings;

use Moo;

use namespace::clean;

=head1 NAME

 BOM::User::Client::PaymentTransaction - A class that stores a payment transation.
 Any object of the class represents a transaction created by a payment action.

=head1 SYNOPSIS

    my $txn = $dbic->run(
        fixup => sub {
            $_->selectrow_hashref("SELECT from payment.add_payment_transaction(...)", ...);
        });

    return BOM::User::Client::PaymentTransaction->new(%$txn);

=head1 DESCRIPTION

This module is an object oriented wrapper around the output of 
C<payment.add_payment_transaction> function, representing a payment transaction just created.

=cut

has id => (
    is => 'ro',
);

has payment_id => (
    is => 'ro',
);

has account_id => (
    is => 'ro',
);

has amount => (
    is => 'ro',
);

has quantity => (
    is => 'ro',
);

has action_type => (
    is => 'ro',
);

has balance_after => (
    is => 'ro',
);

has transaction_time => (
    is => 'ro',
);

has financial_market_bet_id => (
    is => 'ro',
);

has staff_loginid => (
    is => 'ro',
);

has referrer_type => (
    is => 'ro',
);

has source => (
    is => 'ro',
);

has app_markup => (
    is => 'ro',
);

has remark => (
    is => 'ro',
);

has payment_gateway_code => (
    is => 'ro',
);

has payment_type_code => (
    is => 'ro',
);

has transfer_fees => (
    is => 'ro',
);

has status => (
    is => 'ro',
);

has transaction_id => (is => 'lazy');

sub _build_transaction_id {
    my $self = shift;
    return $self->id;
}

1;
