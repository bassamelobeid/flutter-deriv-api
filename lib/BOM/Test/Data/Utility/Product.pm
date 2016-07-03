package BOM::Test::Data::Utility::Product;
use strict;
use warnings;

use feature 'state';
use Scalar::Util qw(blessed);
use BOM::Product::Transaction;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Market::Underlying;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

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

    local $ENV{REQUEST_STARTTIME} = $now->epoch;
    my $txn = BOM::Product::Transaction->new({
        client   => $client,
        contract => $contract,
        price    => $amount,
        staff    => 'system'
    });
    return $txn->buy(skip_validation => 1);
}

sub buy_bet {
    my ($sc, $curr, $client, $price, $start) = @_;

    local $ENV{REQUEST_STARTTIME} = blessed($start) && $start->isa('Date::Utility') ? $start->epoch : $start
    my $txn = BOM::Product::Transaction->new({
        contract => produce_contract($sc, $curr),
        client   => $client,
        price    => $price,
        staff    => 'UnitTest',
    });
    $txn->buy(skip_validation => 1);
    return $txn->contract_id;
}

sub sell_bet {
    my ($sc, $curr, $client, $price, $txn_buy_contract_id) = @_;

    my $txn = BOM::Product::Transaction->new({
        contract    => produce_contract($sc, $curr),
        client      => $client,
        price       => $price,
        staff       => 'UnitTest',
        contract_id => $txn_buy_contract_id,
    });
    return $txn->sell(skip_validation => 1);
}

sub prepare_contract_db {
    my $underlying_symbol = shift || 'R_50';
    state $already_prepared = 0;
    return 1 if $already_prepared;
    initialize_realtime_ticks_db();
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD);
    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'randomindex',
        {
            symbol => $underlying_symbol,
            date   => Date::Utility->new
        });
    $already_prepared = 1;
    return 1;
}

sub create_contract {
    my %args              = @_;
    my $underlying_symbol = $args{underlying} // 'R_50';
    my $is_expired        = $args{is_expired} // 0;
    my $tick_epoches      = $args{tick_epoches} // [];

    my $start_time = $args{start_time} // time;
    my $start      = Date::Utility->new($start_time);
    my $interval   = $args{interval} // '2m';
    $start = $start->minus_time_interval('1h')->minus_time_interval($interval) if $is_expired;

    my $expire = $start->plus_time_interval($interval);
    prepare_contract_db($underlying_symbol);

    my @ticks;
    my @epoches = ($start->epoch, $start->epoch + 1, $expire->epoch);
    push @epoches, @$tick_epoches;
    @epoches = sort { $a <=> $b } @epoches;
    for my $epoch (@epoches) {
        my $api = BOM::Market::Data::DatabaseAPI->new(underlying => $underlying_symbol);
        my $tick = $api->tick_at({end_time => $epoch});

        unless ($tick) {
            # this number should be similar with the quotes in BOM::Test::Data::Utility::UnitTestRedis::get_test_realtime_ticks,
            # otherwise it will produce the error of 'Barrier too far'
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
                epoch      => $epoch,
                quote      => '963.3000',
                underlying => $underlying_symbol
            });
        }
        push @ticks, $tick;
    }

    my $underlying = BOM::Market::Underlying->new($underlying_symbol);

    my $contract_data = {
        underlying            => $underlying,
        bet_type              => 'CALL',
        currency              => 'USD',
        amount_type           => $args{basis} // 'payout',
        amount                => 100,
        date_start            => $start->epoch,
        date_expiry           => $expire->epoch,
        current_tick          => $ticks[1],
        entry_tick            => $ticks[0],
        exit_tick             => $ticks[-1],
        barrier               => 'S0P',
        app_markup_percentage => $args{app_markup_percentage} // 0
    };
    if ($args{is_spread}) {
        delete $contract_data->{date_expiry};
        $contract_data->{bet_type}         = 'SPREADU';
        $contract_data->{amount_per_point} = 1;
        $contract_data->{stop_type}        = 'point';
        $contract_data->{stop_profit}      = 10;
        $contract_data->{stop_loss}        = 10;
    }
    return produce_contract($contract_data);
}

1;

