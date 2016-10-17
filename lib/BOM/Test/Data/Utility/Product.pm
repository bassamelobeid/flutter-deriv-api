package BOM::Test::Data::Utility::Product;
use strict;
use warnings;

use feature 'state';
use Scalar::Util qw(blessed);
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::MarketData qw(create_underlying);
use Date::Utility;
use Postgres::FeedDB;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

sub buy_bet {
    my ($sc, $curr, $client, $price, $start) = @_;

    local $ENV{REQUEST_STARTTIME} = blessed($start) && $start->isa('Date::Utility') ? $start->epoch : $start;
    my $txn = BOM::Product::Transaction->new({
        contract => produce_contract($sc, $curr),
        client   => $client,
        price    => $price,
        staff    => 'UnitTest',
    });
    $txn->buy(skip_validation => 1);
    return $txn->contract_id;
}

1;

