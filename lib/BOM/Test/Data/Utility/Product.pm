package BOM::Test::Data::Utility::Product;

use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Market::Underlying;
use Date::Utility;


sub client_buy_bet {
    my ($client, $currency, $amount) = @_;

    my $now        = Date::Utility->new;
    my $underlying = BOM::Market::Underlying->new('R_50');

    my $account     = $client->default_account;
    my $pre_balance = $account->load->balance;

    my $contract = produce_contract({
        underlying  => $underlying,
        bet_type    => 'FLASHU',
        currency    => $currency,
        payout      => 2 * $amount,
        date_start  => $now,
        date_expiry => $now->epoch + 300,
    });

    local $ENV{REQUEST_STARTTIME} = $now;
    my $txn = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
        price    => $amount,
        staff    => 'system'
    });
    $txn->buy(skip_validation => 1);
}

1;

