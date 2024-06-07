## no critic (RequireExplicitPackage)
use strict;
use warnings;

sub get_event_by_type {
    my $type = shift;
    unless (defined $type) {
        return undef;
    }
    my %event_name = (
        'DEBIT'               => 'payment_debit_withdrawal',
        'CREDIT'              => 'payment_credit_deposit',
        'WITHDRAWAL_REVERSAL' => 'payment_withdrawal_reversal_event',
        'DEPOSIT_REVERSAL'    => 'payment_deposit_reversal',
    );

    return $event_name{$type};
}
1;
