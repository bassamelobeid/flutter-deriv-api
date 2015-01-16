use strict;
use warnings;

use Test::More qw( no_plan );
use Test::Exception;
use Test::MockModule;
use Test::MockObject::Extends;
use List::Util qw( first );
use File::Spec;
use JSON qw(decode_json);

use BOM::Utility::Date;
use BOM::Market::Underlying;
use BOM::RiskReporting::Dashboard;
use BOM::Platform::Runtime;
use BOM::Utility::CurrencyConverter qw(in_USD);
use BOM::Test::Data::Utility::TestDatabaseFixture;
use aliased "BOM::Test::Data::Utility::TestDatabaseFixture" => "DBFixture";
use BOM::Test::Data::Utility::UnitTestCouchDB qw( :init );
use BOM::Test::Data::Utility::UnitTestRedis qw(update_combined_realtime);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $fix       = 'BOM::Test::Data::Utility::TestDatabaseFixture';
my $now       = BOM::Utility::Date->new;
my $plus5mins = BOM::Utility::Date->new(time + 300);

my $usd_gbp_rate = 1.5;

DBFixture->new('exchange')->create;

lives_ok {
    map {
        update_combined_realtime(
            datetime   => BOM::Utility::Date->new($now->epoch - 1),
            underlying => BOM::Market::Underlying->new($_),
            tick       => {
                quote => $usd_gbp_rate,
            })
    } qw(frxGBPUSD frxAUDUSD frxEURUSD);
}
'realtime tick frxGBPUSD';

lives_ok {
    $fix->new(
        'exchange_rate',
        {
            source_currency => 'GBP',
            rate            => $usd_gbp_rate
        })->create;
}
'Insert GBP exchange rate to db';

subtest big_movers => sub {
    plan tests => 10;

    my $USDaccount = $fix->new('account')->create;

    lives_ok {
        # deposit
        $fix->new(
            'payment_deposit',
            {
                account_id => $USDaccount->id,
                amount     => 200,
                remark     => 'Credit Card Deposit'
            })->create;
    }
    'Successfully deposit';

    my $start_time  = $now;
    my $expiry_time = $plus5mins;

    my %bet_hash = (
        bet_type          => 'FLASHU',
        relative_barrier  => 'S0P',
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 100,
        buy_price         => 53,
        purchase_time     => $now->datetime_yyyymmdd_hhmmss,
        start_time        => $start_time->datetime_yyyymmdd_hhmmss,
        expiry_time       => $expiry_time->datetime_yyyymmdd_hhmmss,
        settlement_time   => $plus5mins->datetime_yyyymmdd_hhmmss,
    );

    my @shortcode_param = (
        $bet_hash{bet_type}, $bet_hash{underlying_symbol},
        $bet_hash{payout_price}, $start_time->epoch, $expiry_time->epoch, $bet_hash{relative_barrier}, 0
    );
    my $fmb = $fix->new(
        'fmb_higher_lower',
        {
            %bet_hash,
            account_id => $USDaccount->id,
            short_code => uc join('_', @shortcode_param)})->create;
    $fix->new(
        'realtime_book',
        {
            financial_market_bet_id => $fmb->id,
            market_price            => 160,
        })->create;

    my $results = BOM::RiskReporting::Dashboard->new(end => BOM::Utility::Date->new(time + 1))->generate;

    ok(exists $results->{open_bets}->{pivot},   'We got a pivot table for open bets.');
    ok(exists $results->{open_bets}->{treemap}, 'We got a treemap for open bets.');

    my @movers = @{$results->{open_bets}->{top_ten_movers}};
    my $mover = first { $_->{loginid} eq $USDaccount->client_loginid } @movers;

    ok($mover, 'Our client exists in big movers.');
    is($mover->{id}, $fmb->id, 'Our bet exists in big movers.');

    my $expected_percentage = sprintf '%.1f', (160 / 53 - 1) * 100;
    cmp_ok($mover->{percentage_change}, '==', $expected_percentage, 'Percentage change.');

    my $GBPaccount = $fix->new('account', {currency_code => 'GBP'})->create;

    lives_ok {
        # deposit
        $fix->new(
            'payment_deposit',
            {
                account_id => $GBPaccount->id,
                amount     => 200,
                remark     => 'Credit Card Deposit'
            })->create;
    }
    'Successfully deposit';

    $fmb = $fix->new(
        'fmb_higher_lower',
        {
            %bet_hash,
            account_id => $GBPaccount->id,
            short_code => uc join('_', @shortcode_param)})->create;

    $fix->new(
        'realtime_book',
        {
            financial_market_bet_id => $fmb->id,
            market_price            => in_USD(160, 'GBP'),
        })->create;

    $results = BOM::RiskReporting::Dashboard->new(end => BOM::Utility::Date->new(time + 1))->generate;
    @movers  = @{$results->{open_bets}->{top_ten_movers}};
    $mover   = first { $_->{loginid} eq $GBPaccount->client_loginid } @movers;

    ok($mover, 'Our GBP client exists in big movers.');
    is($mover->{id}, $fmb->id, 'Our GBP bet exists in big movers.');
    cmp_ok($mover->{percentage_change}, '==', $expected_percentage, 'Percentage change for GBP client.');
};

subtest 'Deposits and withdrawals.' => sub {
    plan tests => 6;

    my $depositer     = $fix->new('account')->create;
    my $GBP_depositer = $fix->new('account', {currency_code => 'GBP'})->create;
    my $withdrawer    = $fix->new('account')->create;

    $fix->new(
        'payment_deposit',
        {
            amount           => 500,
            account_id       => $depositer->id,
            transaction_time => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
            payment_time     => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
        })->create;
    $fix->new(
        'payment_deposit',
        {
            amount           => 500,
            account_id       => $GBP_depositer->id,
            transaction_time => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
            payment_time     => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
        })->create;

    $fix->new(
        'payment_deposit',
        {
            amount           => 150,
            account_id       => $withdrawer->id,
            transaction_time => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
            payment_time     => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
        })->create;

    my $start_time  = $now;
    my $expiry_time = $plus5mins;

    my %bet_hash = (
        bet_type          => 'FLASHU',
        relative_barrier  => 'S0P',
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 200,
        buy_price         => 50,
        sell_price        => 200,
        purchase_time     => $now->datetime_yyyymmdd_hhmmss,
        start_time        => $start_time->datetime_yyyymmdd_hhmmss,
        expiry_time       => $expiry_time->datetime_yyyymmdd_hhmmss,
        settlement_time   => $plus5mins->datetime_yyyymmdd_hhmmss,
    );

    my @shortcode_param = (
        $bet_hash{bet_type}, $bet_hash{underlying_symbol},
        $bet_hash{payout_price}, $start_time->epoch, $expiry_time->epoch, $bet_hash{relative_barrier}, 0
    );

    $fix->new(
        'fmb_higher_lower_sold_won',
        {
            %bet_hash,
            account_id => $withdrawer->id,
            short_code => uc join('_', @shortcode_param)})->create;

    $fix->new(
        'payment_withdraw',
        {
            amount           => -250,
            account_id       => $withdrawer->id,
            transaction_time => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
            payment_time     => BOM::Utility::Date->new->datetime_yyyymmdd_hhmmss,
        })->create;

    my $results = BOM::RiskReporting::Dashboard->new(end => BOM::Utility::Date->new(time + 1))->generate;

    my $reported_depositer     = first { $_->{loginid} eq $depositer->client_loginid } @{$results->{big_deposits}};
    my $reported_GBP_depositer = first { $_->{loginid} eq $GBP_depositer->client_loginid } @{$results->{big_deposits}};
    my $reported_withdrawer    = first { $_->{loginid} eq $withdrawer->client_loginid } @{$results->{big_withdrawals}};

    ok($reported_depositer,     'Depositer is present.');
    ok($reported_GBP_depositer, 'GBP depositer is present.');
    ok($reported_withdrawer,    'Withdrawer is present.');

    cmp_ok($reported_depositer->{usd_payments}, '==', 500, 'Depositer deposit amount.');
    cmp_ok($reported_GBP_depositer->{usd_payments}, '==', in_USD(500, 'GBP'), 'GBP depositer deposit amount.');
    cmp_ok($reported_withdrawer->{usd_payments}, '==', -100, 'Withdrawer withdrawal amount.');
};

