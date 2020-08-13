#!/usr/bin/perl
use strict;
use warnings;

use Test::More;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Cryptocurrency::Helper qw(get_crypto_withdrawal_pending_total get_crypto_transactions);

subtest 'get_crypto_withdrawal_pending_total' => sub {
    my $withdrawal_sum = get_crypto_withdrawal_pending_total('CR', 'eUSDT');

    is $withdrawal_sum->{pending_withdrawal_amount}, 0, 'Correct value for pending_withdrawal_amount';
    is $withdrawal_sum->{pending_estimated_fee},     0, 'Correct value for pending_estimated_fee';
};

subtest 'get_crypto_transactions' => sub {
    my %params = (
        loginid => 'CR123456',
        limit   => 50
    );
    my $trx_list = get_crypto_transactions('CR', 'deposit', %params);

    isa_ok $trx_list, 'ARRAY', 'Returns an arrayref';
    is scalar $trx_list->@*, 0, 'Returned empty for the given parameters';
};

done_testing();
