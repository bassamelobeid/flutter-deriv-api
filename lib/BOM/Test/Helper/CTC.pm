package BOM::Test::Helper::CTC;

use strict;
use warnings;

use Exporter qw( import );
use BOM::CTC::Helper;
use BOM::CTC::Currency;
use BOM::Platform::Client::CashierValidation;

our @EXPORT_OK = qw( wait_miner );

BEGIN {
    *BOM::Platform::Client::CashierValidation::is_crypto_currency_suspended = sub {
        return 0;
    };
}

=head2 wait_miner

Wait until a transaction is mined into a block.

This is a workaround until we can run tests asynchronously in bom-cryptocurrency.

=cut

sub wait_miner {
    my ($currency_code, $txhash) = @_;
    return undef unless $txhash;

    my $currency = BOM::CTC::Currency->new($currency_code);

    my $transaction;
    do {
        sleep 1;
        $transaction = $currency->rpc_client()->eth_getTransactionByHash($txhash);
    } until defined $transaction->{blockNumber};

    return undef;
}

1;
