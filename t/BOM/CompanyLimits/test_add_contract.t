#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 2;
use Test::Warnings;
use Test::Exception;
use JSON::MaybeXS;

use BOM::CompanyLimits::Limits;

use Date::Utility;
use BOM::Test;
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Contract qw(create_contract buy_contract sell_contract);
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $redis = BOM::Config::RedisReplicated::redis_limits_write;
my $json  = JSON::MaybeXS->new;

# Test for the correct key combinations
#subtest 'Combinations matching test', sub {
#    my $cl = create_client;
#    top_up $cl, 'USD', 5000;
#    
#};

# Test with different underlying

subtest 'Different landing companies test', sub {
    
    my $cr_cl = create_client('CR');
    my $mx_cl = create_client('MX');
    
    top_up $cr_cl, 'USD', 5000;
    top_up $mx_cl, 'USD', 5000;
    
    BOM::CompanyLimits::Limits::update_company_limits({
        landing_company => 'svg',
        underlying      => 'R_50',
        expiry_type     => 'tick',
        contract_group  => 'callput',
        barrier_type    => 'non_atm',
        limit_type      => 'potential_loss',
        limit_amount    => 100,
    });
    
    BOM::CompanyLimits::Limits::update_company_limits({
        landing_company => 'iom',
        underlying      => 'R_50',
        expiry_type     => 'tick',
        contract_group  => 'callput',
        barrier_type    => 'non_atm',
        limit_type      => 'potential_loss',
        limit_amount    => 100,
    });
    
    my ($svg_contract, $svg_trx, $svg_fmb, $mx_contract, $mx_trx, $mx_fmb);

    $svg_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($svg_trx, $svg_fmb) = buy_contract(
        client    => $cr_cl,
        buy_price => 2,
        contract  => $svg_contract,
    );
    
    my $key = 'tn,R_50,callput';
    
    my $svg_total = $redis->hget('svg:potential_loss', $key);
    my $mx_total = $redis->hget('iom:potential_loss', $key) // 0;
    
    cmp_ok $svg_total, '==', 4, 'buying contract with CR client adds potential loss to svg';
    cmp_ok $mx_total, '==', 0, 'buying contract with CR client does not affect mx potential_loss';
    
    $mx_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($mx_trx, $mx_fmb) = buy_contract(
        client    => $mx_cl,
        buy_price => 2,
        contract  => $mx_contract,
    );
    
    $svg_total = $redis->hget('svg:potential_loss', $key);
    $mx_total = $redis->hget('iom:potential_loss', $key);

    cmp_ok $svg_total, '==', 4, 'buying contract with MX client does not add potential loss to svg';
    cmp_ok $mx_total, '==', 4, 'buying contract with MX client affects mx potential_loss';
    
    $redis->hdel('svg:potential_loss', $key);
    $redis->hdel('iom:potential_loss', $key);
};

# Test with different barrier

# Test with different currencies

# Test with different contract groups

# Test with daily loss and daily turnover

# Test when limits have breached

# Test if database and redis are synced properly

# Test for potential loss reconciliation

subtest 'Limits test base case', sub {
    my $cl = create_client;
    top_up $cl, 'USD', 5000;

    # Apply a potential loss limit on a single underlying, then buy 2 contracts;
    # second one will trigger limit breach.

    BOM::CompanyLimits::Limits::update_company_limits({
        landing_company => 'svg',
        underlying      => 'R_50',
        expiry_type     => 'tick',
        contract_group  => 'callput',
        barrier_type    => 'non_atm',
        limit_type      => 'potential_loss',
        limit_amount    => 100,
    });

    my ($contract, $trx, $fmb, $total);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
    );

    ($trx, $fmb) = buy_contract(
        client    => $cl,
        buy_price => 2,
        contract  => $contract,
    );

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
    is $error->{'-mesg'}, 'company-wide risk limit reached', 'Company-wide risk error thrown';
    is $error->{'-message_to_client'}, 'No further trading is allowed on this contract type for the current trading session.',
        'Correct error description in error object';

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 0, 'If contract failed to buy, it should be reverted';

    # CUT OFF POINT
    # Ignore tests below (email will be moved away)
    # TODO: we will transfer email to bom-events. Commented email code here is kept for reference

    # Check email to see if email is published
    # my $trade_suspended_email = mailbox_search(email => 'x-quants@binary.com');

    # ok $trade_suspended_email, 'some email is received (should be trade suspended)!';
    # my $expected_email = {
    #     'from'    => 'system@binary.com',
    #     'body'    => '{"is_market_default":0,"contract_group":"callput","market_or_symbol":"R_50","expiry_type":"tick","barrier_type":null}',
    #     'to'      => ['x-quants@binary.com', 'x-marketing@binary.com', 'compliance@binary.com', 'x-cs@binary.com'],
    #     'subject' => 'TRADING SUSPENDED! global_potential_loss LIMIT is crossed for landing company svg. Limit set: 100. Current amount: 400'
    # };
    # my $expected_body        = $json->decode(delete $expected_email->{body});
    # my $trade_suspended_body = $json->decode(delete $trade_suspended_email->{body});

    # is_deeply $trade_suspended_body,  $expected_body,  'In suspended email, Json body matches expected output';
    # is_deeply $trade_suspended_email, $expected_email, 'In suspended email, Email matches very specific format';

    # BOM::Config::Runtime->instance->app_config->quants->global_potential_loss_alert_threshold(0.5);

    # $contract = create_contract(
    #     payout     => 90,
    #     underlying => 'R_50',
    # );
    # lives_ok {
    #     buy_contract(
    #         client    => $cl,
    #         buy_price => 20,
    #         contract  => $contract,
    #     );
    # }
    # 'Should still be able to buy contract; warning threshold breach not actual limit breach';

    # my $threshold_warning_email = mailbox_search(email => 'x-quants@binary.com');

    # ok $threshold_warning_email, 'some email is received (should be warning threshold)!';
    # $expected_email = {
    #     'body'    => '{"market_or_symbol":"R_50","is_market_default":0,"barrier_type":null,"expiry_type":"tick","contract_group":"callput"}',
    #     'to'      => ['x-quants@binary.com'],
    #     'subject' => 'global_potential_loss THRESHOLD is crossed for landing company svg. Limit set: 100. Current amount: 70',
    #     'from'    => 'system@binary.com'
    # };
    # $expected_body = $json->decode(delete $expected_email->{body});
    # my $threshold_warning_body = $json->decode(delete $threshold_warning_email->{body});

    # is_deeply $threshold_warning_body,  $expected_body,  'In threshold email, Json body matches expected output';
    # is_deeply $threshold_warning_email, $expected_email, 'In threshold email, Email matches very specific format';

};

