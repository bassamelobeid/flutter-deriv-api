use strict;
use warnings;

use Test::More;
use subs::subs_bo_email_notification;

# Test cases for get_event_by_type
subtest 'Test get_event_by_type' => sub {
    my %expected_events = (
        'DEBIT'               => 'payment_debit_withdrawal',
        'CREDIT'              => 'payment_credit_deposit',
        'WITHDRAWAL_REVERSAL' => 'payment_withdrawal_reversal_event',
        'DEPOSIT_REVERSAL'    => 'payment_deposit_reversal',
    );

    foreach my $type (keys %expected_events) {
        is(get_event_by_type($type), $expected_events{$type}, "Returned correct event for type '$type'");
    }
};

# Test cases for get_event_by_type with undefined type
subtest 'Test get_event_by_type with undefined type' => sub {
    is(get_event_by_type(undef), undef, "Returned undefined for undefined type");
};

# Test cases for get_event_by_type with invalid type
subtest 'Test get_event_by_type with invalid type' => sub {
    my $type = 'test';
    is(get_event_by_type($type), undef, "Returned undefined for invalid type '$type'");
};

done_testing();
