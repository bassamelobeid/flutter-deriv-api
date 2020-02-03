use strict;
use warnings;

use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;

use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use BOM::Product::ContractFactory qw( produce_contract );
use Cache::RedisDB;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => $_,
        recorded_date => Date::Utility->new
    }) for qw(USD JPY JPY-USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'frxUSDJPY',
        recorded_date => Date::Utility->new,
    });
test_with_feed(
    [['2008-01-18', 106.42, 107.59, 106.38, 106.88], ['2008-02-13', 107.36, 108.38, 106.99, 108.27]],
    'Call Long Term' => sub {

        my $bet_params = {
            bet_type    => 'CALL',
            date_expiry => Date::Utility->new('13-Feb-08')->plus_time_interval('23h59m59s'),    # 107.36 108.38 106.99 108.27
            date_start  => '18-Jan-08',                                                         # 106.42 107.59 106.38 106.88
            underlying  => 'frxUSDJPY',
            payout      => 1,
            currency    => 'USD',
        };

        # Closing price on 13-Feb-08 is 108.27
        my %barrier_win_map = (
            108.26 => 1,
            108.0  => 1,
            108.28 => 0,
            109    => 0,
        );

        foreach my $barrier (sort { $a <=> $b } keys %barrier_win_map) {
            $bet_params->{barrier} = $barrier;
            my $bet = produce_contract($bet_params);
            is($bet->is_expired, 1, 'Past end of bet, so it is expired.');
            is($bet->value, $barrier_win_map{$barrier}, 'Correct expiration for strike of ' . $barrier);
        }

        # On the nail.
        $bet_params->{barrier} = 108.27;
        my $bet = produce_contract($bet_params);
        is($bet->is_expired, 1, 'Past end of bet, so it is expired.');
        is($bet->value,      0, 'Expiration for on-the-nail strike.');

        $bet_params->{date_pricing} = '19-Jan-08';
        $bet = produce_contract($bet_params);
        is($bet->is_expired, 0, 'Settlement after pricing date.');
    });

test_with_feed(
    [['2009-02-13 05:24:13', 64285.11, 'R_100'], ['2009-02-13 05:24:15', 63948.31, 'R_100'], ['2009-02-13 05:29:13', 63948.31, 'R_100'],],
    'Call Short Term' => sub {

        my $bet_params = {
            bet_type    => 'CALL',
            date_start  => '1234502653',    # 13-Feb-09 05:24:13 64285.11 64285.11 64285.11
            date_expiry => '1234502953',    # 13-Feb-09 05:29:13 63948.31 63948.31 63948.31
            underlying  => 'R_100',
            payout      => 1,
            currency    => 'USD',
        };

        # Closing price 63948.31
        my %barrier_win_map = (
            63949    => 0,
            63948.32 => 0,
            63948.31 => 0,
            63948.30 => 1,
            63947    => 1,
            'S1P'    => 0,
        );

        foreach my $barrier (keys %barrier_win_map) {
            $bet_params->{barrier} = $barrier;
            my $bet = produce_contract($bet_params);
            is($bet->is_expired, 1, 'Past end of bet, so it is expired.');
            is($bet->value, $barrier_win_map{$barrier}, 'Correct expiration for strike of ' . $barrier);
        }
    });

test_with_feed(
    [['2008-01-18', 106.42, 107.59, 106.38, 106.88], ['2008-02-13', 107.36, 108.38, 106.99, 108.27],],
    'Put Long Term' => sub {
        my $bet_params = {
            bet_type    => 'PUT',
            date_expiry => Date::Utility->new('13-Feb-08')->plus_time_interval('23h59m59s'),    # 13-Feb-08 107.36 108.38 106.99 108.27
            date_start  => 1200614400,                                                          # 18-Jan-08 106.42 107.59 106.38 106.88
            underlying  => 'frxUSDJPY',
            payout      => 1,
            currency    => 'USD',
        };

        # Closing price on 13-Feb-08 is 108.27
        my %barrier_win_map = (
            108.26 => 0,
            108.27 => 0,
            108.0  => 0,
            108.28 => 1,
            109    => 1,
        );

        foreach my $barrier (keys %barrier_win_map) {
            $bet_params->{barrier} = $barrier;
            my $bet = produce_contract($bet_params);
            is($bet->is_expired, 1, 'Past end of bet, so it is expired.');
            is($bet->value, $barrier_win_map{$barrier}, 'Correct expiration for strike of ' . $barrier);
        }
    });

test_with_feed(
    [['2009-02-13 05:24:13', 64285.11, 'R_100'], ['2009-02-13 05:24:15', 63948.31, 'R_100'], ['2009-02-13 05:29:13', 63948.31, 'R_100'],],
    'Put Short Term' => sub {
        my $bet_params = {
            bet_type    => 'PUT',
            date_start  => '1234502653',    # 13-Feb-09 05:24:13 64285.11 64285.11 64285.11
            date_expiry => '1234502953',    # 13-Feb-09 05:29:13 63948.31 63948.31 63948.31
            underlying  => 'R_100',
            payout      => 1,
            currency    => 'USD',
        };

        # Closing price 63948.31
        my %barrier_win_map = (
            63949    => 1,
            63948.32 => 1,
            63948.31 => 0,
            63948.30 => 0,
            63947    => 0,
        );

        foreach my $barrier (keys %barrier_win_map) {
            $bet_params->{barrier} = $barrier;
            my $bet = produce_contract($bet_params);
            is($bet->is_expired, 1, 'Past end of bet, so it is expired.');
            is($bet->value, $barrier_win_map{$barrier}, 'Correct expiration for strike of ' . $barrier);
        }
    });

test_with_feed(
    [['2008-03-18 00:50:01', 96.938], ['2008-03-18 00:55:00', 97.013], ['2008-03-18 15:00:01', 98.359], ['2008-03-18 15:02:00', 98.318],],
    'Flash Down' => sub {
        my $bet_params = {
            bet_type    => 'PUT',
            date_start  => 1205801400,
            date_expiry => 1205801700,
            underlying  => 'frxUSDJPY',
            payout      => 1,
            currency    => 'USD',
            barrier     => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        is($bet->is_expired, 1, 'Past end of bet, thus expired');
        is($bet->value,      0, 'Loses in this period.');

        $bet_params->{date_start}  = 1205852400;    # 18-Mar-08 15:00:01 15:00 098.34 098.38 98.3597 FXN
        $bet_params->{date_expiry} = 1205852520;    # 18-Mar-08 15:01:59 15:01 098.30 098.33 98.3184 FXN

        $bet = produce_contract($bet_params);
        is($bet->is_expired, 1, 'Past end of bet, thus expired');
        is($bet->value,      1, 'Wins in this period.');

    });

test_with_feed(
    [['2008-03-18 00:50:01', 96.938], ['2008-03-18 00:55:00', 97.013], ['2008-03-18 15:00:01', 98.359], ['2008-03-18 15:02:00', 98.318],],
    'Flash Up' => sub {
        my $bet_params = {
            bet_type    => 'CALL',
            date_start  => 1205801400,
            date_expiry => 1205801700,
            underlying  => 'frxUSDJPY',
            payout      => 1,
            currency    => 'USD',
            barrier     => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        is($bet->is_expired, 1, 'Past end of bet, thus expired');
        is($bet->value,      1, 'Loses in this period.');

        $bet_params->{date_start}  = 1205852400;    # 18-Mar-08 15:00:01 15:00 098.34 098.38 98.3597 FXN
        $bet_params->{date_expiry} = 1205852520;    # 18-Mar-08 15:01:59 15:01 098.30 098.33 98.3184 FXN

        $bet = produce_contract($bet_params);
        is($bet->is_expired, 1, 'Past end of bet, thus expired');
        is($bet->value,      0, 'Wins in this period.');

    });

test_with_feed([
        ['2008-03-01 00:00:01', 99.258],            #fake tick to ensure that we get the right entry price.
        ['2008-03-02 00:00:01', 99.841],            #fake tick to ensure that we get the right entry price.
        ['2008-03-18 00:00:01', 97.115],
        ['2008-03-18 00:50:01', 96.938],
        ['2008-03-18 00:55:00', 97.013],
        ['2008-03-18 15:00:01', 98.359],
        ['2008-03-18 15:02:00', 98.318],
        ['2008-03-18 23:58:59', 99.840],
        ['2008-03-19 00:02:00'],
    ],
    'Double Down.' => sub {

        my $bet_params = {
            bet_type     => 'PUT',
            date_expiry  => Date::Utility->new('18-Mar-08')->plus_time_interval('23h59m59s'),
            date_start   => 1204329600,
            date_pricing => Date::Utility->new('2008-03-20T17:00:00Z'),
            underlying   => 'frxUSDJPY',
            market       => 'forex',
            payout       => 1000,
            currency     => 'JPY',
            barrier      => 'S0P',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # WIN TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        $bet_params->{date_start} = 1204416000;
        $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1,            'Bet expired');
        is($bet->value,      $bet->payout, 'Bet outcome won');
    });

test_with_feed([
        ['2008-03-01 00:00:01', 99.258],    #fake tick to ensure that we get the right entry price.
        ['2008-03-02 00:00:01', 99.841],    #fake tick to ensure that we get the right entry price.
        ['2008-03-18 00:00:01', 97.115],
        ['2008-03-18 00:50:01', 96.938],
        ['2008-03-18 00:55:00', 97.013],
        ['2008-03-18 15:00:01', 98.359],
        ['2008-03-18 15:02:00', 98.318],
        ['2008-03-18 23:58:59', 99.840],
        ['2008-03-19 00:02:00'],
    ],
    'Double Up.' => sub {

        my $bet_params = {
            bet_type     => 'CALL',
            date_expiry  => Date::Utility->new('18-Mar-08')->plus_time_interval('23h59m59s'),
            date_start   => 1204329600,
            date_pricing => Date::Utility->new('2008-03-20T17:00:00Z'),
            underlying   => 'frxUSDJPY',
            market       => 'forex',
            payout       => 1000,
            currency     => 'JPY',
            barrier      => 'S0P',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1,            'Bet expired');
        is($bet->value,      $bet->payout, 'Bet outcome won');

        # WIN TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        $bet_params->{date_start} = 1204416000;
        $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');
    });

test_with_feed(
    [['2008-03-18 15:00:01', 98.356], ['2008-03-18 15:59:59', 98.240], ['2008-03-18 16:00:01', 98.232], ['2008-03-18 17:00:00', 98.367],],
    'Intraday down.' => sub {

        my $bet_params = {
            bet_type                   => 'PUT',
            date_start                 => 1205856000,                                   # 16:00:01 16:00 098.23 098.23 98.2328 TDF
            date_expiry                => 1205859600,                                   # 17:00:00 17:00 098.33 098.36 98.3491 GFT
            date_pricing               => Date::Utility->new('2008-03-19T15:30:00Z'),
            underlying                 => 'frxUSDJPY',
            payout                     => 1000,
            market                     => 'forex',
            currency                   => 'USD',
            barrier                    => 'S0P',
            starts_as_forward_starting => 1,
            is_forward_starting        => 1
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # WIN TEST
        $bet_params->{date_start}  = 1205852401;    # 18-Mar-08 15h00 15:00:01 15:00 098.34 098.38 98.3597 FXN
        $bet_params->{date_expiry} = 1205856000;    # 18-Mar-08 16h00 16:00:01 16:00 098.23 098.23 98.2328 TDF

        $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1,            'Bet expired');
        is($bet->value,      $bet->payout, 'Bet outcome won');
    });

test_with_feed([
        ['2008-03-18 15:00:00', 98.356],
        ['2008-03-18 15:59:59', 98.240],
        ['2008-03-18 16:00:01', 98.232],
        ['2008-03-18 16:50:00', 98.353],
        ['2008-03-18 17:00:00', 98.367],
    ],
    'Intraday up.' => sub {

        my $bet_params = {
            bet_type                   => 'CALL',
            date_start                 => 1205856000,                                   # 16:00:01 16:00 098.23 098.23 98.2328 TDF
            date_expiry                => 1205859600,                                   # 17:00:00 17:00 098.33 098.36 98.3491 GFT
            date_pricing               => Date::Utility->new('2008-03-19T15:30:00Z'),
            underlying                 => 'frxUSDJPY',
            payout                     => 1000,
            currency                   => 'USD',
            barrier                    => 'S0P',
            starts_as_forward_starting => 1,
        };

        my $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1,            'Bet expired');
        is($bet->value,      $bet->payout, 'Bet outcome won');

        $bet_params->{date_start}  = 1205852400;                      # 18-Mar-08 15h00 15:00:01 15:00 098.34 098.38 98.3597 FXN
        $bet_params->{date_expiry} = 1205856000;                      # 18-Mar-08 16h00 16:00:01 16:00 098.23 098.23 98.2328 TDF
        $bet                       = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        $bet_params->{today}       = 1205859000;                      # 18-Mar-08 16:50:00
        $bet_params->{date_expiry} = 1205859600;                      # 18-Mar-08 17:00:00
        $bet                       = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet->payout,
            'Bet outcome: win (for Client). Only wins if both entry and exit are the current market value, i.e. "previous tick"');

        lives_ok { $bet = produce_contract('CALL_FRXUSDJPY_300_1205859000F_1205859600_S0P_0', 'USD'); } 'Create CALL from shortcode';
        lives_ok { $bet->is_expired } 'Expiry Check (from shortcode)';
        is($bet->is_expired,           1,      'Bet expired');
        is($bet->barrier->as_absolute, 98.353, 'Barrier is properly set based on current market value when creating Intraday Up from shortcode.');
    });

test_with_feed([
        ['2008-03-01 00:00:01', 99.258],    #fake tick to ensure that we get the right entry price.
        ['2008-03-02 00:00:01', 99.841],    #fake tick to ensure that we get the right entry price.
        ['2008-03-18 00:00:01', 97.115],
        ['2008-03-18 00:44:33', 96.856],
        ['2008-03-18 22:13:37', 100.45],
        ['2008-03-18 23:59:59', 99.840],
        ['2008-03-19'],
    ],
    'Double up.' => sub {

        my $bet_params = {
            bet_type     => 'CALL',
            date_expiry  => Date::Utility->new('18-Mar-08')->plus_time_interval('23h59m59s'),
            date_start   => 1204329600,
            date_pricing => Date::Utility->new('2008-03-20T17:00:00Z'),
            underlying   => 'frxUSDJPY',
            payout       => 1000,
            currency     => 'JPY',
            barrier      => 'S0P',
        };

        my $bet = produce_contract($bet_params);

        # WIN TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1,            'Bet expired');
        is($bet->value,      $bet->payout, 'Bet outcome won');

        # LOSE TEST
        # Close of trading on 18Mar08 is 99.840 => 23:58:59 23:58 099.83 099.86 99.8406 CMC
        $bet_params->{date_start} = 1204416000;
        $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');
    });

test_with_feed([
        ['2008-01-18', 106.42, 107.59, 106.38, 106.88],
        ['21-Jan-08',  106.90, 106.97, 105.62, 105.67],
        ['22-Jan-08',  105.65, 107.21, 105.62, 107.10],
        ['23-Jan-08',  107.09, 107.38, 104.97, 106.67],
        ['24-Jan-08',  106.75, 107.24, 105.94, 107.17],
        ['25-Jan-08',  107.18, 107.90, 106.64, 106.70],
        ['28-Jan-08',  106.76, 107.14, 106.00, 106.98],
        ['29-Jan-08',  106.98, 107.24, 106.38, 107.02],
        ['30-Jan-08',  107.08, 107.47, 106.03, 106.23],
        ['31-Jan-08',  106.22, 106.87, 105.71, 106.27],
        ['1-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['2-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['3-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['4-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['5-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['6-Feb-08',   106.25, 106.73, 105.76, 106.52],
    ],
    'One Touch.' => sub {

        # The high/low during this period is [104.97,107.74]
        my $bet_params = {
            bet_type    => 'ONETOUCH',
            date_expiry => Date::Utility->new('5-Feb-08')->plus_time_interval('23h59m59s'),
            date_start  => 1200614400,
            underlying  => 'frxUSDJPY',
            payout      => 1000,
            barrier     => 108.22,
            currency => 'JPY',    # Price in domestic currency 'JPY', with 'USD' as underlying
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (high barrier too high)');

        $bet_params->{barrier} = 107.91;
        $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (high barrier too high)');

        $bet_params->{barrier} = 104.9;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (low barrier too low)');

        # WIN TEST
        $bet_params->{barrier} = 107.9;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won (high barrier breached)');

        $bet_params->{barrier} = 107.89;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won (high barrier breached)');

        $bet_params->{barrier} = 104.98;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won (low barrier breached)');
    });

test_with_feed([
        ['2009-02-13 05:24:01', 64221.92, 'R_100',],
        ['2009-02-13 05:24:06', 64252.90, 'R_100',],
        ['2009-02-13 05:24:11', 64285.11, 'R_100',],
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:24:21', 64256.47, 'R_100',],
        ['2009-02-13 05:24:26', 64215.92, 'R_100',],
        ['2009-02-13 05:24:31', 64189.18, 'R_100',],
        ['2009-02-13 05:24:36', 64151.23, 'R_100',],
        ['2009-02-13 05:24:41', 64213.43, 'R_100',],
        ['2009-02-13 05:24:46', 64226.39, 'R_100',],
        ['2009-02-13 05:24:51', 64263.09, 'R_100',],
        ['2009-02-13 05:24:56', 64259.75, 'R_100',],
        ['2009-02-13 05:25:01', 64278.26, 'R_100',],
        ['2009-02-13 05:25:06', 64275.57, 'R_100',],
        ['2009-02-13 05:25:11', 64268.42, 'R_100',],
        ['2009-02-13 05:25:16', 64262.08, 'R_100',],
        ['2009-02-13 05:25:21', 64265.57, 'R_100',],
        ['2009-02-13 05:25:26', 64257.84, 'R_100',],
        ['2009-02-13 05:25:31', 64290.84, 'R_100',],
        ['2009-02-13 05:25:36', 64311.17, 'R_100',],
        ['2009-02-13 05:25:41', 64323.80, 'R_100',],
        ['2009-02-13 05:25:46', 64324.91, 'R_100',],
        ['2009-02-13 05:25:51', 64276.33, 'R_100',],
        ['2009-02-13 05:25:56', 64228.56, 'R_100',],
        ['2009-02-13 05:26:01', 64169.64, 'R_100',],
        ['2009-02-13 05:26:06', 64150.16, 'R_100',],
        ['2009-02-13 05:26:11', 64162.90, 'R_100',],
        ['2009-02-13 05:26:16', 64157.34, 'R_100',],
        ['2009-02-13 05:26:22', 64106.80, 'R_100',],
        ['2009-02-13 05:26:27', 64157.21, 'R_100',],
        ['2009-02-13 05:26:32', 64175.50, 'R_100',],
        ['2009-02-13 05:26:37', 64142.31, 'R_100',],
        ['2009-02-13 05:26:42', 64132.49, 'R_100',],
        ['2009-02-13 05:26:47', 64153.54, 'R_100',],
        ['2009-02-13 05:26:52', 64128.55, 'R_100',],
        ['2009-02-13 05:26:57', 64107.64, 'R_100',],
        ['2009-02-13 05:27:02', 64074.73, 'R_100',],
        ['2009-02-13 05:27:07', 64055.52, 'R_100',],
        ['2009-02-13 05:27:12', 64092.66, 'R_100',],
        ['2009-02-13 05:27:17', 64110.90, 'R_100',],
        ['2009-02-13 05:27:22', 64074.82, 'R_100',],
        ['2009-02-13 05:27:27', 64050.97, 'R_100',],
        ['2009-02-13 05:27:32', 64014.70, 'R_100',],
        ['2009-02-13 05:27:37', 64002.81, 'R_100',],
        ['2009-02-13 05:27:42', 64056.00, 'R_100',],
        ['2009-02-13 05:27:47', 64049.17, 'R_100',],
        ['2009-02-13 05:27:52', 64049.42, 'R_100',],
        ['2009-02-13 05:27:57', 64069.90, 'R_100',],
        ['2009-02-13 05:28:02', 64058.38, 'R_100',],
        ['2009-02-13 05:28:07', 64065.63, 'R_100',],
        ['2009-02-13 05:28:12', 64100.96, 'R_100',],
        ['2009-02-13 05:28:17', 64073.80, 'R_100',],
        ['2009-02-13 05:28:22', 64042.82, 'R_100',],
        ['2009-02-13 05:28:27', 64066.88, 'R_100',],
        ['2009-02-13 05:28:32', 64077.90, 'R_100',],
        ['2009-02-13 05:28:37', 64085.01, 'R_100',],
        ['2009-02-13 05:28:42', 64054.91, 'R_100',],
        ['2009-02-13 05:28:47', 64020.96, 'R_100',],
        ['2009-02-13 05:28:52', 63989.26, 'R_100',],
        ['2009-02-13 05:28:57', 63955.60, 'R_100',],
        ['2009-02-13 05:29:02', 63951.66, 'R_100',],
        ['2009-02-13 05:29:07', 63957.44, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],
        ['2009-02-13 05:29:22', 63954.99, 'R_100',],
        ['2009-02-13 05:29:27', 63964.80, 'R_100',],
        ['2009-02-13 05:29:32', 63963.10, 'R_100',],
        ['2009-02-13 05:29:37', 63949.71, 'R_100',],
        ['2009-02-13 05:29:42', 63909.59, 'R_100',],
        ['2009-02-13 05:29:47', 63844.76, 'R_100',],
        ['2009-02-13 05:29:52', 63820.92, 'R_100',],
        ['2009-02-13 05:29:57', 63819.07, 'R_100',],
    ],
    'One Touch Short Term.' => sub {

        # The high/low during this period is [63948.31, 64324.91]
        my $bet_params = {
            bet_type    => 'ONETOUCH',
            date_start  => 1234502653,    # 13-Feb-09 05:24:13
            date_expiry => 1234502953,    # 13-Feb-09 05:29:13
            underlying  => 'R_100',
            payout      => 200,
            H           => 3772,
            currency    => 'GBP',
        };

        my $bet;

        # LOSE TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64325.91;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (high barrier too high)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64324.92;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (high barrier too high)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 63948.30;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (low barrier too low)');

        # WIN TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64324.91;
        $bet = produce_contract($bet_params);
        # Create a new object for that
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome won (high barrier breached)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64324.89;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome won (high barrier breached)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 63948.32;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome won (low barrier breached)');

        $bet_params->{barrier} = 'S0P';
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->value, 0, 'barrier == spot One touch is not valued.');
    });

test_with_feed([
        ['2008-01-18', 106.42, 107.59, 106.38, 106.88],
        ['21-Jan-08',  106.90, 106.97, 105.62, 105.67],
        ['22-Jan-08',  105.65, 107.21, 105.62, 107.10],
        ['23-Jan-08',  107.09, 107.38, 104.97, 106.67],
        ['24-Jan-08',  106.75, 107.24, 105.94, 107.17],
        ['25-Jan-08',  107.18, 107.90, 106.64, 106.70],
        ['28-Jan-08',  106.76, 107.14, 106.00, 106.98],
        ['29-Jan-08',  106.98, 107.24, 106.38, 107.02],
        ['30-Jan-08',  107.08, 107.47, 106.03, 106.23],
        ['31-Jan-08',  106.22, 106.87, 105.71, 106.27],
        ['1-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['2-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['3-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['4-Feb-08',   106.25, 106.73, 105.76, 106.52],
        ['5-Feb-08',   106.25, 106.73, 105.76, 106.52],
    ],
    'No Touch.' => sub {

        my $bet_params = {
            bet_type    => 'NOTOUCH',
            date_expiry => Date::Utility->new('5-Feb-08')->plus_time_interval('23h59m59s'),
            date_start  => 1200614400,
            underlying  => 'frxUSDJPY',
            payout      => 1000,
            barrier     => 108,
            currency    => 'JPY',
        };

        my $bet = produce_contract($bet_params);

        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome lost (high barrier too high)');

        $bet_params->{barrier} = 107;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome won (high barrier breached)');

        $bet_params->{barrier} = 104.9;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome lost (low barrier too low)');

        $bet_params->{barrier} = 104.98;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome won (low barrier breached)');
    });

test_with_feed([
        ['2009-02-13 05:24:01', 64221.92, 'R_100',],
        ['2009-02-13 05:24:06', 64252.90, 'R_100',],
        ['2009-02-13 05:24:11', 64285.11, 'R_100',],
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:24:21', 64256.47, 'R_100',],
        ['2009-02-13 05:24:26', 64215.92, 'R_100',],
        ['2009-02-13 05:24:31', 64189.18, 'R_100',],
        ['2009-02-13 05:24:36', 64151.23, 'R_100',],
        ['2009-02-13 05:24:41', 64213.43, 'R_100',],
        ['2009-02-13 05:24:46', 64226.39, 'R_100',],
        ['2009-02-13 05:24:51', 64263.09, 'R_100',],
        ['2009-02-13 05:24:56', 64259.75, 'R_100',],
        ['2009-02-13 05:25:01', 64278.26, 'R_100',],
        ['2009-02-13 05:25:06', 64275.57, 'R_100',],
        ['2009-02-13 05:25:11', 64268.42, 'R_100',],
        ['2009-02-13 05:25:16', 64262.08, 'R_100',],
        ['2009-02-13 05:25:21', 64265.57, 'R_100',],
        ['2009-02-13 05:25:26', 64257.84, 'R_100',],
        ['2009-02-13 05:25:31', 64290.84, 'R_100',],
        ['2009-02-13 05:25:36', 64311.17, 'R_100',],
        ['2009-02-13 05:25:41', 64323.80, 'R_100',],
        ['2009-02-13 05:25:46', 64324.91, 'R_100',],
        ['2009-02-13 05:25:51', 64276.33, 'R_100',],
        ['2009-02-13 05:25:56', 64228.56, 'R_100',],
        ['2009-02-13 05:26:01', 64169.64, 'R_100',],
        ['2009-02-13 05:26:06', 64150.16, 'R_100',],
        ['2009-02-13 05:26:11', 64162.90, 'R_100',],
        ['2009-02-13 05:26:16', 64157.34, 'R_100',],
        ['2009-02-13 05:26:22', 64106.80, 'R_100',],
        ['2009-02-13 05:26:27', 64157.21, 'R_100',],
        ['2009-02-13 05:26:32', 64175.50, 'R_100',],
        ['2009-02-13 05:26:37', 64142.31, 'R_100',],
        ['2009-02-13 05:26:42', 64132.49, 'R_100',],
        ['2009-02-13 05:26:47', 64153.54, 'R_100',],
        ['2009-02-13 05:26:52', 64128.55, 'R_100',],
        ['2009-02-13 05:26:57', 64107.64, 'R_100',],
        ['2009-02-13 05:27:02', 64074.73, 'R_100',],
        ['2009-02-13 05:27:07', 64055.52, 'R_100',],
        ['2009-02-13 05:27:12', 64092.66, 'R_100',],
        ['2009-02-13 05:27:17', 64110.90, 'R_100',],
        ['2009-02-13 05:27:22', 64074.82, 'R_100',],
        ['2009-02-13 05:27:27', 64050.97, 'R_100',],
        ['2009-02-13 05:27:32', 64014.70, 'R_100',],
        ['2009-02-13 05:27:37', 64002.81, 'R_100',],
        ['2009-02-13 05:27:42', 64056.00, 'R_100',],
        ['2009-02-13 05:27:47', 64049.17, 'R_100',],
        ['2009-02-13 05:27:52', 64049.42, 'R_100',],
        ['2009-02-13 05:27:57', 64069.90, 'R_100',],
        ['2009-02-13 05:28:02', 64058.38, 'R_100',],
        ['2009-02-13 05:28:07', 64065.63, 'R_100',],
        ['2009-02-13 05:28:12', 64100.96, 'R_100',],
        ['2009-02-13 05:28:17', 64073.80, 'R_100',],
        ['2009-02-13 05:28:22', 64042.82, 'R_100',],
        ['2009-02-13 05:28:27', 64066.88, 'R_100',],
        ['2009-02-13 05:28:32', 64077.90, 'R_100',],
        ['2009-02-13 05:28:37', 64085.01, 'R_100',],
        ['2009-02-13 05:28:42', 64054.91, 'R_100',],
        ['2009-02-13 05:28:47', 64020.96, 'R_100',],
        ['2009-02-13 05:28:52', 63989.26, 'R_100',],
        ['2009-02-13 05:28:57', 63955.60, 'R_100',],
        ['2009-02-13 05:29:02', 63951.66, 'R_100',],
        ['2009-02-13 05:29:07', 63957.44, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],
        ['2009-02-13 05:29:22', 63954.99, 'R_100',],
        ['2009-02-13 05:29:27', 63964.80, 'R_100',],
        ['2009-02-13 05:29:32', 63963.10, 'R_100',],
        ['2009-02-13 05:29:37', 63949.71, 'R_100',],
        ['2009-02-13 05:29:42', 63909.59, 'R_100',],
        ['2009-02-13 05:29:47', 63844.76, 'R_100',],
        ['2009-02-13 05:29:52', 63820.92, 'R_100',],
        ['2009-02-13 05:29:57', 63819.07, 'R_100',],
    ],
    'No Touch Short Term.' => sub {

        # The high/low during this period is [63948.31, 64324.91]
        my $bet_params = {
            bet_type    => 'NOTOUCH',
            date_start  => '1234502653',    # 13-Feb-09 05:24:13
            date_expiry => '1234502953',    # 13-Feb-09 05:29:13
            underlying  => 'R_100',
            payout      => '20',
            barrier     => '63400',
            currency    => 'GBP',
        };

        my $bet = produce_contract($bet_params);

        # High barrier too high (never breached during bet period)
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64325;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome lost (high barrier too high)');

        # Lower the high barrier to win
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 64323;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome won (high barrier breached)');

        # barrier too low (never breached during bet period)
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 63947.31;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{payout}, 'Bet outcome lost (low barrier too low)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 63949;
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome won (low barrier breached)');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{barrier} = 'S4000P';
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, 0,
            'Bet outcome: lose (relative "+40" barrier was hit). Wouldn\'t hit (i.e. would win) if "current market value" was used to calculate barrier.'
        );
    });

test_with_feed(
    [['2008-01-09 00:00:02', 110.12], ['2008-01-09 23:58:59', 110.12], ['2008-02-06', 106.53, 106.80, 106.18, 106.40]],
    'Expiry range.' => sub {

        my $bet_params = {
            bet_type     => 'EXPIRYRANGE',
            date_expiry  => Date::Utility->new('6-Feb-08')->plus_time_interval('23h59m59s'),    # 6-Feb-08 106.53 106.80 106.18 106.40
            date_start   => 1199836800,                                                         # 9-Jan-08 108.97 110.12 108.82 109.87
            underlying   => 'frxUSDJPY',
            payout       => 1000,
            high_barrier => 106.50,                                                             # in range
            low_barrier  => 104.70,                                                             # in range
            currency => 'JPY',    # Price in domestic currency 'JPY', with 'USD' as underlying
        };

        my $bet = produce_contract($bet_params);

        # WIN TEST
        # The price at expiry is 106.4
        $bet = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 107.00;                          # in range
        $bet_params->{'low_barrier'}  = 106.39;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # LOSE TEST
        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 110.11;                          # in range
        $bet_params->{'low_barrier'}  = 106.41;                          # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 106.39;                          # out of range
        $bet_params->{'low_barrier'}  = 104.98;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 106.40;                          # out of range
        $bet_params->{'low_barrier'}  = 104.97;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (spot hits high barrier exactly)');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.40;                          # out of range
        $bet_params->{'low_barrier'}  = 106.40;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (spot hits low barrier exactly)');
    });

test_with_feed([
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],                     #Extra trick required to ensure that 29:13 is same as 29:12
    ],
    'Expiry range short term.' => sub {

        my $bet_params = {
            bet_type     => 'EXPIRYRANGE',
            date_start   => '1234502653',                                # 13-Feb-09 05:24:13 64285.11 64285.11 64285.11
            date_expiry  => '1234502953',                                # 13-Feb-09 05:29:13 63948.31 63948.31 63948.31
            underlying   => 'R_100',
            payout       => 20,
            high_barrier => 63948.30,
            low_barrier  => 63948.32,
            currency     => 'GBP',
        };

        my $bet = produce_contract($bet_params);

        # WIN TEST
        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63948.32;                        # in range
        $bet_params->{'low_barrier'}  = 63948.30;                        # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63949;                           # in range
        $bet_params->{'low_barrier'}  = 63948;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # LOSE TEST
        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63949;                           # in range
        $bet_params->{'low_barrier'}  = 63948.4;                         # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63947;                           # out of range
        $bet_params->{'low_barrier'}  = 63946;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');
    });

test_with_feed(
    [['2008-01-09 00:00:01', 110.12], ['2008-01-09 23:58:59', 110.12], ['2008-02-06', 106.53, 106.80, 106.18, 106.40]],
    'Expiry miss.' => sub {

        my $bet_params = {
            bet_type     => 'EXPIRYMISS',
            date_expiry  => Date::Utility->new('6-Feb-08')->plus_time_interval('23h59m59s'),    # 6-Feb-08 106.53 106.80 106.18 106.40
            date_start   => 1199836800,                                                         # 9-Jan-08 108.97 110.12 108.82 109.87
            underlying   => 'frxUSDJPY',
            payout       => 1000,
            high_barrier => 112.0,
            low_barrier  => 106.0,
            currency     => 'JPY',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 112;                             # in range
        $bet_params->{'low_barrier'}  = 105;                             # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 106.41;                          # in range
        $bet_params->{'low_barrier'}  = 106.39;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 107.0;                           # in range
        $bet_params->{'low_barrier'}  = 106.4;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (spot hits low barrier exactly)');

        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 106.4;                           # in range
        $bet_params->{'low_barrier'}  = 103.4;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost (spot hits high barrier exactly)');

        # WIN TEST
        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 106.39;                          # up
        $bet_params->{'low_barrier'}  = 105.00;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The price at expiry is 106.4
        $bet_params->{'high_barrier'} = 107.0;                           # in range
        $bet_params->{'low_barrier'}  = 106.5;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');
    });

test_with_feed([
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],                     #Extra trick required to ensure that 29:13 is same as 29:12
    ],
    'Expiry miss short term.' => sub {

        my $bet_params = {
            bet_type     => 'EXPIRYMISS',
            date_start   => '1234502653',                                # 13-Feb-09 05:24:13 64285.11 64285.11 64285.11
            date_expiry  => '1234502953',                                # 13-Feb-09 05:29:13 63948.31 63948.31 63948.31
            underlying   => 'R_100',
            payout       => 20,
            high_barrier => 63948.30,
            low_barrier  => 63948.32,
            currency     => 'GBP',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63948.32;                        # in range
        $bet_params->{'low_barrier'}  = 63948.30;                        # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # WIN TEST
        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63948.30;                        # up
        $bet_params->{'low_barrier'}  = 63940;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The price at expiry is 63948.31
        $bet_params->{'high_barrier'} = 63950;                           # in range
        $bet_params->{'low_barrier'}  = 63949;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');
    });

test_with_feed([
        ['9-Jan-08',  108.97, 110.12, 108.82, 109.87],
        ['10-Jan-08', 109.89, 110.08, 109.10, 109.61],
        ['11-Jan-08', 109.62, 109.71, 108.63, 108.80],
        ['14-Jan-08', 108.85, 108.96, 107.37, 108.26],
        ['15-Jan-08', 108.27, 108.27, 106.59, 106.76],
        ['16-Jan-08', 106.77, 107.92, 105.92, 107.37],
        ['17-Jan-08', 107.37, 107.87, 106.34, 106.45],
        ['18-Jan-08', 106.42, 107.59, 106.38, 106.88],
        ['21-Jan-08', 106.90, 106.97, 105.62, 105.67],
        ['22-Jan-08', 105.65, 107.21, 105.62, 107.10],
        ['23-Jan-08', 107.09, 107.38, 104.97, 106.67],
        ['24-Jan-08', 106.75, 107.24, 105.94, 107.17],
        ['25-Jan-08', 107.18, 107.90, 106.64, 106.70],
        ['28-Jan-08', 106.76, 107.14, 106.00, 106.98],
        ['29-Jan-08', 106.98, 107.24, 106.38, 107.02],
        ['30-Jan-08', 107.08, 107.47, 106.03, 106.23],
        ['31-Jan-08', 106.22, 106.87, 105.71, 106.27],
        ['1-Feb-08',  106.25, 106.73, 105.76, 106.52],
        ['4-Feb-08',  106.59, 107.09, 106.55, 106.70],
        ['5-Feb-08',  106.70, 107.74, 106.39, 106.55],
        ['6-Feb-08',  106.53, 106.80, 106.18, 106.40]
    ],
    'Range.' => sub {

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        my $bet_params = {
            bet_type     => 'RANGE',
            date_expiry  => Date::Utility->new('6-Feb-08')->plus_time_interval('23h59m59s'),    # 6-Feb-08 106.53 106.80 106.18 106.40
            date_start   => 1199836800,                                                         # 9-Jan-08 108.97 110.12 108.82 109.87
            underlying   => 'frxUSDJPY',
            payout       => 1000,
            high_barrier => 110.0,
            low_barrier  => 106.0,
            currency     => 'JPY',
        };

        my $bet = produce_contract($bet_params);

        # WIN TEST
        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.20;                          # in range
        $bet_params->{'low_barrier'}  = 104.80;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.13;                          # in range
        $bet_params->{'low_barrier'}  = 104.39;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # LOSE TEST
        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.11;                          # out of range on first day
        $bet_params->{'low_barrier'}  = 102.00;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.23;                          # in range
        $bet_params->{'low_barrier'}  = 104.98;                          # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.10;                          # out of range
        $bet_params->{'low_barrier'}  = 104.9;                           # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');
    });

test_with_feed([
        ['2009-02-13 05:24:01', 64221.92, 'R_100',],
        ['2009-02-13 05:24:06', 64252.90, 'R_100',],
        ['2009-02-13 05:24:11', 64285.11, 'R_100',],
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:24:21', 64256.47, 'R_100',],
        ['2009-02-13 05:24:26', 64215.92, 'R_100',],
        ['2009-02-13 05:24:31', 64189.18, 'R_100',],
        ['2009-02-13 05:24:36', 64151.23, 'R_100',],
        ['2009-02-13 05:24:41', 64213.43, 'R_100',],
        ['2009-02-13 05:24:46', 64226.39, 'R_100',],
        ['2009-02-13 05:24:51', 64263.09, 'R_100',],
        ['2009-02-13 05:24:56', 64259.75, 'R_100',],
        ['2009-02-13 05:25:01', 64278.26, 'R_100',],
        ['2009-02-13 05:25:06', 64275.57, 'R_100',],
        ['2009-02-13 05:25:11', 64268.42, 'R_100',],
        ['2009-02-13 05:25:16', 64262.08, 'R_100',],
        ['2009-02-13 05:25:21', 64265.57, 'R_100',],
        ['2009-02-13 05:25:26', 64257.84, 'R_100',],
        ['2009-02-13 05:25:31', 64290.84, 'R_100',],
        ['2009-02-13 05:25:36', 64311.17, 'R_100',],
        ['2009-02-13 05:25:41', 64323.80, 'R_100',],
        ['2009-02-13 05:25:46', 64324.91, 'R_100',],
        ['2009-02-13 05:25:51', 64276.33, 'R_100',],
        ['2009-02-13 05:25:56', 64228.56, 'R_100',],
        ['2009-02-13 05:26:01', 64169.64, 'R_100',],
        ['2009-02-13 05:26:06', 64150.16, 'R_100',],
        ['2009-02-13 05:26:11', 64162.90, 'R_100',],
        ['2009-02-13 05:26:16', 64157.34, 'R_100',],
        ['2009-02-13 05:26:22', 64106.80, 'R_100',],
        ['2009-02-13 05:26:27', 64157.21, 'R_100',],
        ['2009-02-13 05:26:32', 64175.50, 'R_100',],
        ['2009-02-13 05:26:37', 64142.31, 'R_100',],
        ['2009-02-13 05:26:42', 64132.49, 'R_100',],
        ['2009-02-13 05:26:47', 64153.54, 'R_100',],
        ['2009-02-13 05:26:52', 64128.55, 'R_100',],
        ['2009-02-13 05:26:57', 64107.64, 'R_100',],
        ['2009-02-13 05:27:02', 64074.73, 'R_100',],
        ['2009-02-13 05:27:07', 64055.52, 'R_100',],
        ['2009-02-13 05:27:12', 64092.66, 'R_100',],
        ['2009-02-13 05:27:17', 64110.90, 'R_100',],
        ['2009-02-13 05:27:22', 64074.82, 'R_100',],
        ['2009-02-13 05:27:27', 64050.97, 'R_100',],
        ['2009-02-13 05:27:32', 64014.70, 'R_100',],
        ['2009-02-13 05:27:37', 64002.81, 'R_100',],
        ['2009-02-13 05:27:42', 64056.00, 'R_100',],
        ['2009-02-13 05:27:47', 64049.17, 'R_100',],
        ['2009-02-13 05:27:52', 64049.42, 'R_100',],
        ['2009-02-13 05:27:57', 64069.90, 'R_100',],
        ['2009-02-13 05:28:02', 64058.38, 'R_100',],
        ['2009-02-13 05:28:07', 64065.63, 'R_100',],
        ['2009-02-13 05:28:12', 64100.96, 'R_100',],
        ['2009-02-13 05:28:17', 64073.80, 'R_100',],
        ['2009-02-13 05:28:22', 64042.82, 'R_100',],
        ['2009-02-13 05:28:27', 64066.88, 'R_100',],
        ['2009-02-13 05:28:32', 64077.90, 'R_100',],
        ['2009-02-13 05:28:37', 64085.01, 'R_100',],
        ['2009-02-13 05:28:42', 64054.91, 'R_100',],
        ['2009-02-13 05:28:47', 64020.96, 'R_100',],
        ['2009-02-13 05:28:52', 63989.26, 'R_100',],
        ['2009-02-13 05:28:57', 63955.60, 'R_100',],
        ['2009-02-13 05:29:02', 63951.66, 'R_100',],
        ['2009-02-13 05:29:07', 63957.44, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],
        ['2009-02-13 05:29:22', 63954.99, 'R_100',],
        ['2009-02-13 05:29:27', 63964.80, 'R_100',],
        ['2009-02-13 05:29:32', 63963.10, 'R_100',],
        ['2009-02-13 05:29:37', 63949.71, 'R_100',],
        ['2009-02-13 05:29:42', 63909.59, 'R_100',],
        ['2009-02-13 05:29:47', 63844.76, 'R_100',],
        ['2009-02-13 05:29:52', 63820.92, 'R_100',],
        ['2009-02-13 05:29:57', 63819.07, 'R_100',],
    ],
    'Range short term.' => sub {

        # The high/low during this period is [63948.31, 64324.91]
        my $bet_params = {
            bet_type     => 'RANGE',
            date_start   => 1234502653,    # 13-Feb-09 05:24:13
            date_expiry  => 1234502953,    # 13-Feb-09 05:29:13
            underlying   => 'R_100',
            payout       => 20,
            high_barrier => 63948.31,
            low_barrier  => 64324.91,
            currency     => 'GBP',
        };

        my $bet = produce_contract($bet_params);

        # WIN TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64330;                           # in range
        $bet_params->{'low_barrier'}  = 63940;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64324.92;                        # in range
        $bet_params->{'low_barrier'}  = 63948.30;                        # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # LOSE TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64324.90;                        # out of range
        $bet_params->{'low_barrier'}  = 63950;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64325;                           # in range
        $bet_params->{'low_barrier'}  = 63950;                           # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64320;                           # out of range
        $bet_params->{'low_barrier'}  = 63950;                           # out of range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');
    });

test_with_feed([
        ['9-Jan-08',  108.97, 110.12, 108.82, 109.87],
        ['10-Jan-08', 109.89, 110.08, 109.10, 109.61],
        ['11-Jan-08', 109.62, 109.71, 108.63, 108.80],
        ['14-Jan-08', 108.85, 108.96, 107.37, 108.26],
        ['15-Jan-08', 108.27, 108.27, 106.59, 106.76],
        ['16-Jan-08', 106.77, 107.92, 105.92, 107.37],
        ['17-Jan-08', 107.37, 107.87, 106.34, 106.45],
        ['18-Jan-08', 106.42, 107.59, 106.38, 106.88],
        ['21-Jan-08', 106.90, 106.97, 105.62, 105.67],
        ['22-Jan-08', 105.65, 107.21, 105.62, 107.10],
        ['23-Jan-08', 107.09, 107.38, 104.97, 106.67],
        ['24-Jan-08', 106.75, 107.24, 105.94, 107.17],
        ['25-Jan-08', 107.18, 107.90, 106.64, 106.70],
        ['28-Jan-08', 106.76, 107.14, 106.00, 106.98],
        ['29-Jan-08', 106.98, 107.24, 106.38, 107.02],
        ['30-Jan-08', 107.08, 107.47, 106.03, 106.23],
        ['31-Jan-08', 106.22, 106.87, 105.71, 106.27],
        ['1-Feb-08',  106.25, 106.73, 105.76, 106.52],
        ['4-Feb-08',  106.59, 107.09, 106.55, 106.70],
        ['5-Feb-08',  106.70, 107.74, 106.39, 106.55],
        ['6-Feb-08',  106.53, 106.80, 106.18, 106.40]
    ],
    'Up or Down.' => sub {

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        my $bet_params = {
            bet_type     => 'UPORDOWN',
            date_expiry  => Date::Utility->new('6-Feb-08')->plus_time_interval('23h59m59s'),    # 6-Feb-08 106.53 106.80 106.18 106.40
            date_start   => 1199836800,                                                         # 9-Jan-08 108.97 110.12 108.82 109.87
            underlying   => 'frxUSDJPY',
            payout       => 1000,
            high_barrier => 110.0,
            low_barrier  => 106.0,
            currency     => 'JPY',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.20;                          # in range
        $bet_params->{'low_barrier'}  = 104.80;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.13;                          # in range
        $bet_params->{'low_barrier'}  = 104.39;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # WIN TEST
        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.11;                          # up
        $bet_params->{'low_barrier'}  = 102.00;                          # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.23;                          # in range
        $bet_params->{'low_barrier'}  = 104.98;                          # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The range from 9 Jan 2008 to 6 Feb 2008 is [104.97,110.12]
        $bet_params->{'high_barrier'} = 110.10;                          # up
        $bet_params->{'low_barrier'}  = 104.9;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');
    });

test_with_feed([
        ['2009-02-13 05:24:01', 64221.92, 'R_100',],
        ['2009-02-13 05:24:06', 64252.90, 'R_100',],
        ['2009-02-13 05:24:11', 64285.11, 'R_100',],
        ['2009-02-13 05:24:16', 64254.16, 'R_100',],
        ['2009-02-13 05:24:21', 64256.47, 'R_100',],
        ['2009-02-13 05:24:26', 64215.92, 'R_100',],
        ['2009-02-13 05:24:31', 64189.18, 'R_100',],
        ['2009-02-13 05:24:36', 64151.23, 'R_100',],
        ['2009-02-13 05:24:41', 64213.43, 'R_100',],
        ['2009-02-13 05:24:46', 64226.39, 'R_100',],
        ['2009-02-13 05:24:51', 64263.09, 'R_100',],
        ['2009-02-13 05:24:56', 64259.75, 'R_100',],
        ['2009-02-13 05:25:01', 64278.26, 'R_100',],
        ['2009-02-13 05:25:06', 64275.57, 'R_100',],
        ['2009-02-13 05:25:11', 64268.42, 'R_100',],
        ['2009-02-13 05:25:16', 64262.08, 'R_100',],
        ['2009-02-13 05:25:21', 64265.57, 'R_100',],
        ['2009-02-13 05:25:26', 64257.84, 'R_100',],
        ['2009-02-13 05:25:31', 64290.84, 'R_100',],
        ['2009-02-13 05:25:36', 64311.17, 'R_100',],
        ['2009-02-13 05:25:41', 64323.80, 'R_100',],
        ['2009-02-13 05:25:46', 64324.91, 'R_100',],
        ['2009-02-13 05:25:51', 64276.33, 'R_100',],
        ['2009-02-13 05:25:56', 64228.56, 'R_100',],
        ['2009-02-13 05:26:01', 64169.64, 'R_100',],
        ['2009-02-13 05:26:06', 64150.16, 'R_100',],
        ['2009-02-13 05:26:11', 64162.90, 'R_100',],
        ['2009-02-13 05:26:16', 64157.34, 'R_100',],
        ['2009-02-13 05:26:22', 64106.80, 'R_100',],
        ['2009-02-13 05:26:27', 64157.21, 'R_100',],
        ['2009-02-13 05:26:32', 64175.50, 'R_100',],
        ['2009-02-13 05:26:37', 64142.31, 'R_100',],
        ['2009-02-13 05:26:42', 64132.49, 'R_100',],
        ['2009-02-13 05:26:47', 64153.54, 'R_100',],
        ['2009-02-13 05:26:52', 64128.55, 'R_100',],
        ['2009-02-13 05:26:57', 64107.64, 'R_100',],
        ['2009-02-13 05:27:02', 64074.73, 'R_100',],
        ['2009-02-13 05:27:07', 64055.52, 'R_100',],
        ['2009-02-13 05:27:12', 64092.66, 'R_100',],
        ['2009-02-13 05:27:17', 64110.90, 'R_100',],
        ['2009-02-13 05:27:22', 64074.82, 'R_100',],
        ['2009-02-13 05:27:27', 64050.97, 'R_100',],
        ['2009-02-13 05:27:32', 64014.70, 'R_100',],
        ['2009-02-13 05:27:37', 64002.81, 'R_100',],
        ['2009-02-13 05:27:42', 64056.00, 'R_100',],
        ['2009-02-13 05:27:47', 64049.17, 'R_100',],
        ['2009-02-13 05:27:52', 64049.42, 'R_100',],
        ['2009-02-13 05:27:57', 64069.90, 'R_100',],
        ['2009-02-13 05:28:02', 64058.38, 'R_100',],
        ['2009-02-13 05:28:07', 64065.63, 'R_100',],
        ['2009-02-13 05:28:12', 64100.96, 'R_100',],
        ['2009-02-13 05:28:17', 64073.80, 'R_100',],
        ['2009-02-13 05:28:22', 64042.82, 'R_100',],
        ['2009-02-13 05:28:27', 64066.88, 'R_100',],
        ['2009-02-13 05:28:32', 64077.90, 'R_100',],
        ['2009-02-13 05:28:37', 64085.01, 'R_100',],
        ['2009-02-13 05:28:42', 64054.91, 'R_100',],
        ['2009-02-13 05:28:47', 64020.96, 'R_100',],
        ['2009-02-13 05:28:52', 63989.26, 'R_100',],
        ['2009-02-13 05:28:57', 63955.60, 'R_100',],
        ['2009-02-13 05:29:02', 63951.66, 'R_100',],
        ['2009-02-13 05:29:07', 63957.44, 'R_100',],
        ['2009-02-13 05:29:12', 63948.31, 'R_100',],
        ['2009-02-13 05:29:17', 63999.50, 'R_100',],
        ['2009-02-13 05:29:22', 63954.99, 'R_100',],
        ['2009-02-13 05:29:27', 63964.80, 'R_100',],
        ['2009-02-13 05:29:32', 63963.10, 'R_100',],
        ['2009-02-13 05:29:37', 63949.71, 'R_100',],
        ['2009-02-13 05:29:42', 63909.59, 'R_100',],
        ['2009-02-13 05:29:47', 63844.76, 'R_100',],
        ['2009-02-13 05:29:52', 63820.92, 'R_100',],
        ['2009-02-13 05:29:57', 63819.07, 'R_100',],
    ],
    'Up or Down short term.' => sub {

        # The high/low during this period is [63948.31, 64324.91]
        my $bet_params = {
            bet_type     => 'UPORDOWN',
            date_start   => 1234502653,    # 13-Feb-09 05:24:13
            date_expiry  => 1234502953,    # 13-Feb-09 05:29:13
            underlying   => 'R_100',
            payout       => 20,
            high_barrier => 63948.31,
            low_barrier  => 64324.91,
            currency     => 'GBP',
        };

        my $bet = produce_contract($bet_params);

        # LOSE TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64324.92;                        # in range
        $bet_params->{'low_barrier'}  = 63948.30;                        # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64325;                           # in range
        $bet_params->{'low_barrier'}  = 63940;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value,      0, 'Bet outcome lost');

        # WIN TEST
        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64324.50;                        # up
        $bet_params->{'low_barrier'}  = 63940;                           # in range
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64326;                           # in range
        $bet_params->{'low_barrier'}  = 63949;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');

        # The high/low during this period is [63948.31, 64324.91]
        $bet_params->{'high_barrier'} = 64320;                           # up
        $bet_params->{'low_barrier'}  = 63930;                           # down
        $bet                          = produce_contract($bet_params);
        lives_ok { $bet->is_expired } 'Expiry Check';
        is($bet->is_expired, 1, 'Bet expired');
        is($bet->value, $bet_params->{'payout'}, 'Bet outcome won');
    });

my $oft_used_date = Date::Utility->new('2013-03-29 15:00:34');

test_with_feed(
    [[$oft_used_date->epoch + 700, 100.11, 'frxUSDJPY'], [$oft_used_date->epoch + 1800, 100.12, 'frxUSDJPY'],],
    'sell if entry tick is within start and expiry' => sub {
        my $underlying = create_underlying('frxUSDJPY');
        my $starting   = $oft_used_date->epoch;

        my $bet_params = {
            underlying => $underlying,
            bet_type   => 'CALL',
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '30m',
            barrier    => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        ok($bet->is_expired,       'The bet is expired');
        ok($bet->is_valid_to_sell, 'valid to sell');

    });
test_with_feed(
    [[$oft_used_date->epoch - 700, 100.11, 'frxUSDJPY'], [$oft_used_date->epoch + 1800, 100.12, 'frxUSDJPY'],],
    'entry_tick is too early on forward starter to allow sale' => sub {
        my $underlying = create_underlying('frxUSDJPY');
        my $starting   = $oft_used_date->epoch;

        my $bet_params = {
            underlying                 => $underlying,
            bet_type                   => 'CALL',
            currency                   => 'USD',
            payout                     => 100,
            date_start                 => $starting,
            duration                   => '30m',
            barrier                    => 'S0P',
            is_forward_starting        => 1,
            starts_as_forward_starting => 1
        };

        my $bet = produce_contract($bet_params);
        ok($bet->is_expired,        'The bet is expired');
        ok(!$bet->is_valid_to_sell, 'but we still cannot sell it');
        like($bet->primary_validation_error->message, qr/entry tick is too old/, 'because the entry tick came too early on the forward starter.');

    });

test_with_feed([
        [$oft_used_date->epoch,        100.11, 'frxUSDJPY'],
        [$oft_used_date->epoch + 1800, 100.12, 'frxUSDJPY'],
        [$oft_used_date->epoch + 1801, 101.00, 'frxUSDJPY'],
    ],
    'cannot buy and sell on the same tick' => sub {
        my $underlying = create_underlying('frxUSDJPY');
        my $starting   = $oft_used_date->epoch;

        my $bet_params = {
            underlying => $underlying,
            bet_type   => 'PUT',
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '30m',
            barrier    => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        ok($bet->is_expired,        'The bet is expired');
        ok(!$bet->is_valid_to_sell, 'but we still cannot sell it');
        like($bet->primary_validation_error->message, qr/only one tick throughout contract period/, 'because entry and exit are the same tick.');

    });

my $midnight_one_day = Date::Utility->new('2013-06-18');
test_with_feed([
        [$midnight_one_day->epoch - 59, 100.11, 'frxUSDJPY'],
        [$midnight_one_day->epoch,      100.12, 'frxUSDJPY'],
        [$midnight_one_day->epoch + 60, 101.00, 'frxUSDJPY'],
    ],
    'can expire across 0000GMT' => sub {
        my $underlying = create_underlying('frxUSDJPY');
        my $starting   = $midnight_one_day->epoch - 60;

        my $bet_params = {
            underlying => $underlying,
            bet_type   => 'PUT',
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '2m',
            barrier    => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        ok($bet->is_expired, 'The bet is expired');
        is($bet->entry_tick->quote, 100.11, '.. since it found the correct entry tick from yesterday.');
        is($bet->exit_tick->quote,  101.00, '.. and it found the correct exit tick from today.');
        is($bet->value,             0,      '.. but did not win, because it went up instead of down as predicted..');
    });

test_with_feed([
        [$oft_used_date->epoch + 1,    100.11, 'frxUSDJPY'],
        [$oft_used_date->epoch + 1000, 100.12, 'frxUSDJPY'],
        [$oft_used_date->epoch + 1801, 101.00, 'frxUSDJPY'],
    ],
    'can sell if exit tick is within start and expiry' => sub {
        my $underlying = create_underlying('frxUSDJPY');
        my $starting   = $oft_used_date->epoch;

        my $bet_params = {
            underlying => $underlying,
            bet_type   => 'PUT',
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '30m',
            barrier    => 'S0P',
        };

        my $bet = produce_contract($bet_params);
        ok($bet->is_expired,       'The bet is expired');
        ok($bet->is_valid_to_sell, 'valid to sell');
    });

test_with_feed([
        [$oft_used_date->epoch + 1, 1000.94, 'R_100'],
        [$oft_used_date->epoch + 3, 1000.83, 'R_100'],
        [$oft_used_date->epoch + 5, 1000.72, 'R_100'],
        [$oft_used_date->epoch + 7, 1000.61, 'R_100'],
        [$oft_used_date->epoch + 9, 1000.50, 'R_100'],
    ],
    'digits contracts' => sub {
        my $underlying = create_underlying('R_100');
        my $starting   = $oft_used_date->epoch;

        my %expectations = (
            DIGITDIFF  => 100,
            DIGITMATCH => 0,
            DIGITODD   => 0,
            DIGITEVEN  => 100,
            DIGITOVER  => 0,
            DIGITUNDER => 100,
        );

        note "For all conditions to pass we must be using the full-width quote with trailing 0";

        my %shared_params = (
            underlying => $underlying,
            currency   => 'USD',
            payout     => 100,
            date_start => $starting,
            duration   => '5t',
        );
        foreach my $bt (sort keys %expectations) {
            my %barrier = $bt =~ /DIGITEVEN|DIGITODD/ ? () : (barrier => 1);
            my $bet = produce_contract({%shared_params, %barrier, bet_type => $bt});
            ok($bet->is_expired, $bt . ' contract is expired');
            cmp_ok($bet->exit_tick->quote, '==', 1000.5,             'numeric comparison of the exit tick works without trailing 0');
            cmp_ok($bet->value,            '==', $expectations{$bt}, '...but we need the correct full-width to settle the ' . $bt);
        }
    });

sub test_with_feed {
    my $setup    = shift;
    my $testname = shift;
    my $test     = shift;

    Cache::RedisDB->flushall;
    BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables;

    foreach my $entry (@$setup) {
        my $date = Date::Utility->new($entry->[0]);
        my $param_hash;
        if (scalar @$entry > 3) {
            #un-official ohlc
            $param_hash->{epoch}      = ($date->epoch + 1);
            $param_hash->{quote}      = $entry->[1];
            $param_hash->{underlying} = $entry->[5] if (scalar @$entry == 6);
            #note "Inserting OHLC " . $entry->[0] . "\n";
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 2000);
            $param_hash->{quote} = $entry->[2];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 4000);
            $param_hash->{quote} = $entry->[3];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
            $param_hash->{epoch} = ($date->epoch + 8000);
            $param_hash->{quote} = $entry->[4];

            $param_hash->{epoch} = ($date->epoch + 86399);
            $param_hash->{quote} = $entry->[4];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);

            $param_hash->{epoch} = ($date->epoch + 86400);
            $param_hash->{quote} = $entry->[4];
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
        } else {
            #note "Inserting " . $entry->[0] . "\n";
            $param_hash->{epoch}      = $date->epoch;
            $param_hash->{quote}      = $entry->[1] if ($entry->[1]);
            $param_hash->{underlying} = $entry->[2] if (scalar @$entry == 3);
            BOM::Test::Data::Utility::FeedTestDatabase::create_tick($param_hash);
        }

    }

    subtest($testname, $test);
}

done_testing;
