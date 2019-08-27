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
    foreach my $landing_company (qw/svg mf mlt mx/) {
        foreach my $k (qw/potential_loss realized_loss turnover limits/) {
            $redis->del("$landing_company:$k");
        }
    }
    $redis->hmset('contractgroups',   ('CALL', 'callput'));
    $redis->hmset('underlyinggroups', ('R_50', 'volidx'));
}

subtest 'Limits test base case', sub {
    setup_tests();
    my $cl = create_client;
    top_up $cl, 'USD', 5000;

    # Apply a potential loss limit on a single underlying, then buy 2 contracts;
    # second one will trigger limit breach.

    my $limit_added = BOM::CompanyLimits::Limits::update_company_limits({
        landing_company => 'svg',
        underlying      => 'R_50',
        expiry_type     => 'tick',
        contract_group  => 'callput',
        barrier_type    => 'non_atm',
        limit_type      => 'potential_loss',
        limit_amount    => 100,
    });

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
    my $key = 'tn,R_50,callput';
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

    my $error = buy_contract(
        client    => $cl,
        buy_price => 200,
        contract  => $contract,
    );

    ok $error, 'error is thrown';
    is $error->{'-mesg'},              'company-wide risk limit reached';
    is $error->{'-message_to_client'}, 'No further trading is allowed on this contract type for the current trading session.';

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'If contract failed to buy, it should be reverted';
};

