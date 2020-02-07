#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);

use Date::Utility;
use Data::Hash::DotNotation;
use BOM::Database::Model::Account;
use BOM::Database::DataMapper::Account;
use BOM::User::Client;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::Product::ContractFactory qw( produce_contract make_similar_contract );
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Transaction;
use BOM::Transaction::Utility qw( TRACK_FMB_ATTR TRACK_CONTRACT_ATTR TRACK_TIME_ATTR);

my $now = Date::Utility->new;
initialize_realtime_ticks_db();

my $loginid = 'CR2002';
my $client  = BOM::User::Client->new({loginid => $loginid});
my $account = $client->set_default_account('USD');
my $db      = $client->set_db('write');
my $comment_str =
    'vega[-0.04668] atmf_fct[1.00000] div[0.00730] recalc[3.46000] int[0.00252] theta[1.53101] iv[0.14200] emp[2.62000] fwdst_fct[1.00000] win[5.00000] trade[3.46000] dscrt_fct[1.00000] spot[1.42080] gamma[-5.51036] delta[-0.07218] theo[2.48000] base_spread[0.39126] ia_fct[1.00000] news_fct[1.00000]';
my $comment_hash = {
    vega        => -0.04668,
    atmf_fct    => 1.00000,
    div         => 0.00730,
    recalc      => 3.46000,
    int         => 0.00252,
    theta       => 1.53101,
    iv          => 0.14200,
    emp         => 2.62000,
    fwdst_fct   => 1.00000,
    win         => 5.00000,
    trade       => 3.46000,
    dscrt_fct   => 1.00000,
    spot        => 1.42080,
    gamma       => -5.51036,
    delta       => -0.07218,
    theo        => 2.48000,
    base_spread => 0.39126,
    ia_fct      => 1.00000,
    news_fct    => 1.00000,
};
my $comment = [$comment_str, $comment_hash];

my $mock_emitter = Test::MockModule->new('BOM::Platform::Event::Emitter');

my @emitted;
$mock_emitter->mock(
    'emit',
    sub {
        push @emitted, [@_];
    });

sub check_emitted_event {
    my %args = @_;

    is scalar @emitted, 1, 'one event is emitted';
    my ($name, $payload) = $emitted[0]->@*;

    is $args{event}, $name, 'event name is correct';

    is $payload->{loginid}, $args{loginid}, 'correct loginid';

    my $fmb = $args{txn}->transaction_record->financial_market_bet;
    my $expected_payload =
        {(map { $_ => $fmb->$_ } TRACK_FMB_ATTR->@*), $args{contract}->%{TRACK_CONTRACT_ATTR->@*}};

    $expected_payload->{loginid}           = $args{loginid};
    $expected_payload->{contract_id}       = $fmb->{id};
    $expected_payload->{balance_after}     = $args{txn}->balance_after;
    $expected_payload->{contract_category} = $args{contract}->category_code;
    $expected_payload->{contract_type}     = $args{contract}->code;
    $expected_payload->{buy_source}        = $args{txn_buy}->{source} if $args{event} eq 'sell';
    $expected_payload->{source}            = $args{txn}->{source};
    $expected_payload->{transaction_id}    = $args{txn}->transaction_id;
    for (qw/copy_trading auto_expired/) { $expected_payload->{$_} = $args{$_} if $args{$_} }

    for my $attr (TRACK_TIME_ATTR->@*) {
        $expected_payload->{$attr} = Date::Utility->new($expected_payload->{$attr})->epoch if $expected_payload->{$attr};
        $payload->{$attr}          = Date::Utility->new($payload->{$attr})->epoch          if $payload->{$attr};
    }
    is_deeply $payload, $expected_payload, 'payout content matches that of db fmb record';
}

subtest 'check duplicate sell with Model' => sub {
    lives_ok {
        # deposit
        $client->smart_payment(
            payment_type => 'free_gift',
            currency     => 'USD',
            amount       => 500,
            remark       => "don't spend it all at once"
        );
    }
    'Successfully deposit';

    my $txn_id;
    my $contract = produce_contract('RANGE_FRXEURUSD_5_1310631887_1310688000_14356_14057', 'USD');
    my $txn_buy;
    my $payload = {
        contract      => $contract,
        amount_type   => 'payout',
        client        => $client,
        price         => 3.46,
        comment       => $comment,
        purchase_date => Date::Utility->new('2011-07-14 08:24:46'),
        source        => 10,
    };
    lives_ok {
        # buy
        $txn_buy = BOM::Transaction->new($payload);
        $txn_buy->buy(skip_validation => 1);
        $txn_id = $txn_buy->transaction_id;
        check_emitted_event(
            event    => 'buy',
            txn      => $txn_buy,
            contract => $contract,
            loginid  => $loginid
        );
        undef @emitted;
    }
    'Successfully buy a bet for an account';

    lives_ok {
        # sell
        my $txn = BOM::Transaction->new({
            contract      => $contract,
            client        => $client,
            amount_type   => 'payout',
            price         => 1.95,
            comment       => $comment,
            contract_id   => $txn_buy->contract_id,
            purchase_date => $contract->date_start,
        });
        $txn->sell(skip_validation => 1);
        $txn_id = $txn->transaction_id;

        check_emitted_event(
            event    => 'sell',
            txn      => $txn,
            contract => $contract,
            txn_buy  => $txn_buy,
            loginid  => $loginid,
        );
        undef @emitted;
    }
    'Successfully sell the bet';

    my $txn = $account->find_transaction(query => [id => $txn_id])->[0];

    my $financial_market_bet = BOM::Database::Model::FinancialMarketBet->new({
        financial_market_bet_record => $txn->financial_market_bet,
        db                          => $db,
    });

    my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
            account_data => {
                client_loginid => $client->loginid,
                currency_code  => $client->currency
            },
            bet => $financial_market_bet,
            db  => $db,
        });
    $financial_market_bet->sell_price(10);
    is $financial_market_bet_helper->sell_bet, undef, 'bet cannot be sold twice';
};

subtest 'check duplicate sell with legacy line' => sub {

    my $txn_id;
    my $contract = produce_contract('UPORDOWN_FRXUSDJPY_2_1311834639_1311897600_784800_770900', 'USD');

    my $txn_buy;
    lives_ok {
        # buy
        $txn_buy = BOM::Transaction->new({
            contract      => $contract,
            client        => $client,
            amount_type   => 'payout',
            price         => 1.2,
            comment       => $comment,
            purchase_date => Date::Utility->new('2011-07-28 06:30:39'),
        });
        $txn_buy->buy(skip_validation => 1);
        $txn_id = $txn_buy->transaction_id;
    }
    'Successfully buy bet for account';

    lives_ok {
        # sell directly with model
        my $txn = $account->find_transaction(query => [id => $txn_id])->[0];

        my $financial_market_bet = BOM::Database::Model::FinancialMarketBet->new({
            financial_market_bet_record => $txn->financial_market_bet,
            db                          => $db,
        });

        my $financial_market_bet_helper = BOM::Database::Helper::FinancialMarketBet->new({
                account_data => {
                    client_loginid => $client->loginid,
                    currency_code  => $client->currency
                },
                bet => $financial_market_bet,
                db  => $db,
            });
        $financial_market_bet->sell_price(10);
        $financial_market_bet_helper->bet_data->{quantity}  = 1;
        $financial_market_bet_helper->bet_data->{sell_time} = Date::Utility::today()->db_timestamp;
        $financial_market_bet_helper->sell_bet // die "Bet not sold";
    }
    'Successfully sold the bet with Model';

    # sell with Transaction::buy_sell_contract
    my $txn = BOM::Transaction->new({
        contract      => $contract,
        client        => $client,
        price         => 0,
        amount_type   => 'payout',
        comment       => $comment,
        contract_id   => $txn_buy->contract_id,
        purchase_date => $contract->date_start,
    });
    my $error = $txn->sell(skip_validation => 1);
    is $error->get_type, 'NoOpenPosition', 'error is NoOpenPosition';
};

subtest 'check buy bet without quants bet params' => sub {
    my $txn_id;

    lives_ok {
        # buy

        my $txn = BOM::Transaction->new({
            contract      => produce_contract('UPORDOWN_FRXUSDJPY_5_1315466633_1315785600_771000_762300', 'USD'),
            client        => $client,
            price         => 1.2,
            amount_type   => 'payout',
            purchase_date => Date::Utility->new('2011-09-08 07:23:53'),
        });
        $txn->buy(skip_validation => 1);
        $txn_id = $txn->transaction_id;
    }
    'Successfully buy a bet for an account, without quants bet params';
    ok $txn_id, "got transaction id";
};

subtest 'check if is valid to sell is correct for sold contracts' => sub {
    my $contract = produce_contract('UPORDOWN_FRXUSDJPY_2_1311834639_1311897600_784800_770900', 'USD', 1);
    is $contract->is_valid_to_sell, 0, 'correct valid to sell for contract already marked as sold';
    is_deeply($contract->primary_validation_error->message_to_client, ['This contract has been sold.']);
};

done_testing();
