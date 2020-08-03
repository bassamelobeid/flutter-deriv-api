#!/usr/bin/perl
use strict;
use warnings;

use Test::More;

use BOM::Cryptocurrency::Helper qw(get_crypto_withdrawal_pending_total);

subtest 'get_crypto_withdrawal_pending_total' => sub {
    my $withdrawal_sum = get_crypto_withdrawal_pending_total('CR', 'eUSDT');

    is $withdrawal_sum->{pending_withdrawal_amount}, 0, 'Correct value for pending_withdrawal_amount';
    is $withdrawal_sum->{pending_estimated_fee},     0, 'Correct value for pending_estimated_fee';
};

done_testing();
