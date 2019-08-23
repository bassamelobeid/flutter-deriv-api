#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;

use BOM::CompanyLimits::Limits;

use Date::Utility;
use BOM::Test;
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Time qw( sleep_till_next_second );
use BOM::Test::Contract qw(create_contract buy_contract sell_contract);
use BOM::Config::RedisReplicated;
use Syntax::Keyword::Try;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;

sub setup_tests {
    $redis->flushall();    # cleanup past data
    $redis->hmset('CONTRACTGROUPS',   ('CALL', 'CALLPUT'));
    $redis->hmset('UNDERLYINGGROUPS', ('R_50', 'volidx'));
}

subtest 'Limits test base case', sub {
    setup_tests();
    my $cl = create_client;
    top_up $cl, 'USD', 5000;

    my $limit_def_hash = {
        underlying_symbol => 'R_50',
        expiry_type       => 'daily',
        barrier_type      => 'atm',
        contract_group    => 'CALLPUT'
    };

    # Apply a potential loss limit on a single underlying, then buy 2 contracts;
    # second one will trigger limit breach.

    # 1. Get the key structure
    my $key = 'tf,R_50,CALLPUT';

    # 2. Set the limit value (somehow)
    # TODO: Visit this later
    my $limit_val = BOM::CompanyLimits::Limits::pack_limit_values([100, 0, 0, 0]);

    # 3. Set in redis
    $redis->hset('svg:limits', $key, $limit_val);

    #BOM::CompanyLimits::Limits::add_limit('POTENTIAL_LOSS', $limit_def_hash, 10, 0, 0);

    my ($contract, $trx, $fmb, $total);

    # 4. Buy contract
    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($trx, $fmb) = buy_contract(
        client    => $cl,
        buy_price => 2,
        contract  => $contract,
    );

    # 5. Ensure the right keys are affected (BOM::CompanyLimits::Combinations::get_combinations)

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 4, 'buying contract adds correct potential loss';

    sell_contract(
        client       => $cl,
        contract_id  => $fmb->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'selling contract with win, deducts potential loss from before';

    # same contract, but we crank up the price hundred fold to exceed limit
    $contract = create_contract(
        payout     => 600,
        underlying => 'R_50',
    );

    my $error = 0;
    throws_ok {
        buy_contract(
            client    => $cl,
            buy_price => 200,
            contract  => $contract,
        );
    }
    qr/CompanyWideLimitExceeded/, 'Throws company wide limit exceeded error and block trade';

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'If contract failed to buy, it should be reverted';
};

