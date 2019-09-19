#!/etc/rmg/bin/perl

use strict;
use warnings;
use Test::MockTime qw/:all/;
use Test::MockModule;
use Test::More tests => 7;
use Test::Warnings;
use Test::Exception;
use JSON::MaybeXS;

use Date::Utility;
use BOM::Test;
use BOM::Test::FakeCurrencyConverter qw(fake_in_usd);
use BOM::Test::Helper::Client qw(create_client top_up);
use BOM::Test::Contract qw(create_contract buy_contract sell_contract);
use BOM::Config::RedisReplicated;
use BOM::Config::Runtime;
use BOM::Test::Email qw(mailbox_search);
use BOM::CompanyLimits::SyncLoss;

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

my $mocked_CurrencyConverter = Test::MockModule->new('ExchangeRates::CurrencyConverter');
$mocked_CurrencyConverter->mock('in_usd', \&fake_in_usd);

my $redis = BOM::Config::RedisReplicated::redis_limits_write;
my $json  = JSON::MaybeXS->new;

# Setup groups:
$redis->hmset('groups:contract', ('CALL', 'callput', 'DIGITEVEN', 'digits', 'LBFLOATCALL', 'lookbacks'));
$redis->hmset('groups:underlying', ('R_50', 'volidx', 'frxUSDJPY', 'forex'));

# Test for the correct key combinations
#subtest 'Key Combinations matching test', sub {

#};

subtest 'Different combinations of contracts', sub {

    top_up my $cr_cl = create_client('CR'), 'USD', 5000;
    my ($contract, $error, $contract_info, $key, $total);

    use Data::Dumper;

    # Contract #1
    $contract = create_contract(
        payout     => 9,
        underlying => 'R_50',
        bet_type   => 'DIGITEVEN',
        duration   => '5t',
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 4,
        contract  => $contract,
    );

    $key = 'tn,R_50,digits';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 5, 'buying digit contract increments correct key';

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 0,
    );

    # Contract #2
    $contract = create_contract(
        payout     => 12,
        underlying => 'frxUSDJPY',
        barrier    => 'S0P',
        bet_type   => 'CALL',
        duration   => '5t',
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $key = 'ta,frxUSDJPY,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 7, 'buying forex contract increments correct key';

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    # Contract #3
    $contract = create_contract(
        payout     => 11,
        underlying => 'R_25',
        bet_type   => 'DIGITEVEN',
        duration   => '5t',
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $key = 'tn,R_25,digits';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 6, 'buying digit contract with different underlying increments correct key';

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 0,
    );

    # Contract #4
    $contract = create_contract(
        payout     => 8,
        underlying => 'R_100',
        barrier    => 'S0P',
        duration   => '5t',
        bet_type   => 'CALL'
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $key = 'ta,R_100,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 3, 'buying volatility contract increments correct key';

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

subtest 'Realized loss and total turnover are on daily basis', sub {

    top_up my $cr_cl = create_client('CR'), 'USD', 5000;

    my ($contract, $error, $contract_info, $key, $realized_loss_total, $turnover_total);
    my $client_key = 't,R_50,callput,' . $cr_cl->binary_user_id;
    $key = 'ta,R_50,callput';

    # Loss and turnover still same on current day
    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        barrier    => 'S0P',
        duration   => '5t',
        bet_type   => 'CALL'
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    $realized_loss_total = $redis->hget('svg:realized_loss', $key);
    $turnover_total      = $redis->hget('svg:turnover',      $client_key);

    cmp_ok $realized_loss_total, '==', 1, 'buying contract increments realized loss (before reset)';
    cmp_ok $turnover_total,      '==', 5, 'buying contract increments total turnover (before reset)';

    # Reset the loss and turnover by using force_reset
    BOM::CompanyLimits::SyncLoss::reset_daily_loss_hashes(force_reset => 1);

    $realized_loss_total = $redis->hget('svg:realized_loss', $key)        // 0;
    $turnover_total      = $redis->hget('svg:turnover',      $client_key) // 0;

    cmp_ok $realized_loss_total, '==', 0, 'realized loss is reset to 0 (after reset)';
    cmp_ok $turnover_total,      '==', 0, 'total turnover is reset to 0 (after reset)';

    # Loss and turnover different on new day
    $contract = create_contract(
        payout     => 11,
        underlying => 'R_50',
        barrier    => 'S0P',
        duration   => '5t',
        bet_type   => 'CALL'
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr_cl,
        buy_price => 6,
        contract  => $contract,
    );

    sell_contract(
        client       => $cr_cl,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    $realized_loss_total = $redis->hget('svg:realized_loss', $key);
    $turnover_total      = $redis->hget('svg:turnover',      $client_key);

    cmp_ok $realized_loss_total, '==', 5, 'buying contract increments realized loss (after reset)';
    cmp_ok $turnover_total,      '==', 6, 'buying contract increments total turnover (after reset)';

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

subtest 'Different underlying tests', sub {
    top_up my $cr_cl = create_client('CR'), 'USD', 5000;

    my ($error, $contract_info_svg, $contract, $key, $total);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P',
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 2,
        contract  => $contract,
    );

    $key = 'ta,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 4, 'buying contract (R_50) increments count (R_50) from 0 to 4';

    $contract = create_contract(
        payout     => 7,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 4,
        contract  => $contract,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 7, 'buying contract (R_50) increments count (R_50) from 4 to 7';

    $contract = create_contract(
        payout     => 8,
        underlying => 'frxUSDJPY',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 7, 'buying contract (frxUSDJPY) keeps count (R_50) at 7';

    $key = 'ta,frxUSDJPY,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 3, 'buying contract (frxUSDJPY) increases count (frxUSDJPY) from 0 to 3';

    $contract = create_contract(
        payout     => 9,
        underlying => 'R_100',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 2,
        contract  => $contract,
    );

    $key = 'ta,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 7, 'buying contract (R_100) keeps count (R_50) from 0 to 3';

    $key = 'ta,frxUSDJPY,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 3, 'buying contract (R_100) keeps count (frxUSDJPY) from 0 to 3';

    $key = 'ta,R_100,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 7, 'buying contract (R_100) increases count (R_100) from 0 to 7';

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

subtest 'Different barrier tests', sub {
    top_up my $cr_cl = create_client('CR'), 'USD', 5000;

    my ($error, $contract_info_svg, $contract, $key, $total);

    # S0P
    $contract = create_contract(
        payout     => 10,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $key = 'ta,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 5, 'buying contract with barrier (a) increases count from 0 to 5';

    # S29P
    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S29P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 5, 'buying contract with barrier (a) keeps count at 5';

    $redis->hdel('svg:potential_loss', $key);

    $key = 'tn,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 1, 'buying contract with barrier (n) increases count from 0 to 1';

    # Random
    $contract = create_contract(
        payout     => 7,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S1234P'
    );

    buy_contract(
        client    => $cr_cl,
        buy_price => 5,
        contract  => $contract,
    );

    $key = 'tn,R_50,callput';
    $total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $total, '==', 3, 'buying contract with barrier (n) increases count from 1 to 3';

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

subtest 'Different landing companies test', sub {

    top_up my $cr_cl = create_client('CR'), 'USD', 5000;
    top_up my $mx_cl = create_client('MX'), 'USD', 5000;

    my ($error, $contract_info_svg, $contract_info_mx, $contract);

    $contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    ($error, $contract_info_svg) = buy_contract(
        client    => $cr_cl,
        buy_price => 2,
        contract  => $contract,
    );

    my $key = 'ta,R_50,callput';

    my $svg_total = $redis->hget('svg:potential_loss', $key);
    my $mx_total = $redis->hget('iom:potential_loss', $key) // 0;

    cmp_ok $svg_total, '==', 4, 'buying contract with CR client adds potential loss to svg';
    cmp_ok $mx_total,  '==', 0, 'buying contract with CR client does not affect mx potential_loss';

    ($error, $contract_info_mx) = buy_contract(
        client    => $mx_cl,
        buy_price => 2,
        contract  => $contract,
    );

    $svg_total = $redis->hget('svg:potential_loss', $key);
    $mx_total  = $redis->hget('iom:potential_loss', $key);

    cmp_ok $svg_total, '==', 4, 'buying contract with MX client does not add potential loss to svg';
    cmp_ok $mx_total,  '==', 4, 'buying contract with MX client affects mx potential_loss';

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

subtest 'Different currencies', sub {
    top_up my $cr_usd = create_client('CR'), 'USD', 5000;
    top_up my $cr_eur = create_client('CR'), 'EUR', 5000;

    my ($error, $contract_info_usd, $contract_info_eur, $usd_contract, $eur_contract);

    $usd_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        currency   => 'USD',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    $eur_contract = create_contract(
        payout     => 6,
        underlying => 'R_50',
        currency   => 'EUR',
        bet_type   => 'CALL',
        duration   => '5t',
        barrier    => 'S0P'
    );

    ($error, $contract_info_usd) = buy_contract(
        client    => $cr_usd,
        buy_price => 2,
        contract  => $usd_contract,
    );

    my $key          = 'ta,R_50,callput';
    my $turnover_key = 't,R_50,callput,';

    my $potential_loss_total = $redis->hget('svg:potential_loss', $key);

    my $usd_turnover_key = $turnover_key . $cr_usd->binary_user_id;
    my $usd_turnover_total = $redis->hget('svg:turnover', $usd_turnover_key);

    cmp_ok $potential_loss_total, '==', 4, 'buying contract with CR (USD) client adds potential loss to svg';
    cmp_ok $usd_turnover_total,   '==', 2, 'Correct turnover for CR(USD)';

    ($error, $contract_info_eur) = buy_contract(
        client    => $cr_eur,
        buy_price => 2,
        contract  => $eur_contract,
    );

    $potential_loss_total = $redis->hget('svg:potential_loss', $key);

    my $eur_turnover_key = $turnover_key . $cr_eur->binary_user_id;
    my $eur_turnover_total = $redis->hget('svg:turnover', $eur_turnover_key);

    cmp_ok $potential_loss_total, '==', 8.72, 'buying contract with CR (EUR) client adds potential loss to svg';
    cmp_ok $eur_turnover_total,   '==', 2.36, 'Total turnover comes from both the EUR and USD contract purchase';

    my $fmb = $contract_info_usd->{fmb};

    sell_contract(
        client       => $cr_usd,
        contract_id  => $fmb->{id},
        contract     => $usd_contract,
        sell_outcome => 1,
    );

    $potential_loss_total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $potential_loss_total, '==', 4.72, 'selling contract with win (CR - USD) deducts potential loss to svg';

    $fmb = $contract_info_eur->{fmb};

    sell_contract(
        client       => $cr_eur,
        contract_id  => $fmb->{id},
        contract     => $eur_contract,
        sell_outcome => 0,
    );

    my $realized_loss_total = $redis->hget('svg:realized_loss', $key);

    $potential_loss_total = $redis->hget('svg:potential_loss', $key);
    cmp_ok $potential_loss_total, '==', 0,    'selling contract with loss (CR - EUR) reduces potential loss to 0';
    cmp_ok $realized_loss_total,  '==', 1.64, 'Realized loss comes from EUR contract loss';

    $redis->del('svg:potential_loss');
    $redis->del('svg:turnover');
    $redis->del('svg:realized_loss');
};

# Test when limits have breached (LATER in v2)
#subtest 'Limits breached tests', sub {

# CR (USD) shows no breach

# CR (USD) shows breach

# CR (EUR) shows breach

# MX (USD) shows no breach for SVG
#};

# Test if database and redis are synced properly (LATER in v2)
#subtest 'Sync between database and redis', sub {

# New contract purchase should sync with database

# Updates should be synced

# On a new day, the previous data:
# 1. should not be impacted,
# 2. redis synced on new day data
#};

subtest 'Contracts with no payout', sub {
    top_up my $cr = create_client('CR'), 'USD', 3;

    my ($contract, $contract_info, $error);
    $contract = create_contract(
        underlying => 'R_50',
        bet_type   => 'LBFLOATCALL',
        multiplier => '5',
        duration   => '1h',
        currency   => 'USD'
    );

    ($error, $contract_info) = buy_contract(
        client    => $cr,
        buy_price => 2,
        contract  => $contract,
    );

    is $error, undef, 'no errors during buy';
    TODO: {
        cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+') || 0, '==', 0, 'Lookbacks do not have potential loss';
    }

    cmp_ok $redis->hget('svg:turnover', "+,R_50,+," . $cr->binary_user_id()), '==', 2, 'Turnover increments works as usual';

    sell_contract(
        client       => $cr,
        contract_id  => $contract_info->{fmb}->{id},
        contract     => $contract,
        sell_outcome => 1,
    );

    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+') || 0, '==', 0, 'On sell potential loss is deducted as before';

    ($error, $contract_info) = buy_contract(
        client    => $cr,
        buy_price => 2,
        contract  => $contract,
    );

    is defined($error), 1, 'Error thrown due to insufficient';
    cmp_ok $redis->hget('svg:potential_loss', '++,R_50,+') || 0, '==', 0, 'On reverse buy potential loss does not change';
};

