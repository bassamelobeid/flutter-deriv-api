#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More;
use Test::Warnings;
use Test::Exception;
use Guard;
use Crypt::NamedKeys;
use BOM::User::Client;
use BOM::User::Password;
use BOM::Config::Runtime;

use BOM::CompanyLimits::Limits;

use Date::Utility;
use BOM::Transaction;
use BOM::Transaction::Validation;
use Math::Util::CalculatedValue::Validatable;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Test::Contract;
use BOM::Platform::Client::IDAuthentication;
use BOM::Config::RedisReplicated;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

sub _clean_redis {
    BOM::Config::RedisReplicated::redis_limits_write->flushall();
}

my $cl;
my $acc_usd;
my $acc_aud;

####################################################################
# real tests begin here
####################################################################

lives_ok {
    $cl = create_client;
    top_up $cl, 'USD', 5000;
}
'client created and funded';

my $new_client = create_client;
top_up $new_client, 'USD', 5000;
my $new_acc_usd = $new_client->account;

sub setup_groups {
    BOM::Config::RedisReplicated::redis_limits_write->hmset('CONTRACTGROUPS',   ('CALL', 'CALLPUT'));
    BOM::Config::RedisReplicated::redis_limits_write->hmset('UNDERLYINGGROUPS', ('R_50', 'volidx'));
}

subtest 'buy a bet', sub {
    plan tests => 2;
    _clean_redis();
    setup_groups();
    BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', 'R_50,,,', 100, 0, 0);
        # my $contract = produce_contract({
        #     underlying   => $underlying,
        #     bet_type     => 'CALL',
        #     currency     => 'USD',
        #     payout       => 1000,
        #     duration     => '15m',
        #     current_tick => $tick,
        #     barrier      => 'S0P',
        # });

        # my $txn = BOM::Transaction->new({
        #     client        => $cl,
        #     contract      => $contract,
        #     price         => 514.00,
        #     payout        => $contract->payout,
        #     amount_type   => 'payout',
        #     source        => 19,
        #     purchase_date => $contract->date_start,
        # });
        # my $error = $txn->buy;
        my $contract = BOM::Test::Contract::create_contract(
            payout => 1000,
            underlying => 'R_50',
            purchase_date  => Date::Utility->new('2019-12-01'),
        );

        my ($trx, $fmb) = BOM::Test::Contract::buy_contract(
            client => $cl,
            contract => $contract,
        );


        BOM::Test::Contract::sell_contract(
            client => $cl,
            contract_id => $fmb->{id},
            contract => $contract,
            sell_outcome => 1,
        );
        # ($trx, $fmb, $chld, $qv1, $qv2) = get_transaction_from_db higher_lower_bet => $txn->transaction_id;

};

# subtest 'sell a bet', sub {
#     plan tests => 2;
#     lives_ok {
#         set_relative_time 1;
#         my $reset_time = guard { restore_time };
#         my $contract = produce_contract({
#             underlying   => $underlying,
#             bet_type     => 'CALL',
#             currency     => 'USD',
#             payout       => 1000,
#             duration     => '15m',
#             current_tick => $tick,
#             entry_tick   => $tick,
#             exit_tick    => $tick,
#             barrier      => 'S0P',
#         });
#         my $txn;
#         #note 'bid price: ' . $contract->bid_price;
#         my $error = do {
#             my $mocked           = Test::MockModule->new('BOM::Transaction');
#             my $mocked_validator = Test::MockModule->new('BOM::Transaction::Validation');
#             $mocked_validator->mock('_validate_trade_pricing_adjustment', sub { });
#             $mocked->mock('price', sub { $contract->bid_price });
#             $txn = BOM::Transaction->new({
#                 purchase_date => $contract->date_start,
#                 client        => $cl,
#                 contract      => $contract,
#                 contract_id   => $fmb->{id},
#                 price         => $contract->bid_price,
#                 source        => 23,
#             });
#             $txn->sell;
#         };
#         is $error, undef, 'no error';
#     }, 'survived';
# };


done_testing;
