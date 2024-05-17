#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Warnings;
use Test::MockModule;

use BOM::MyAffiliatesCFDReport;
use YAML::XS qw(LoadFile);
use BOM::Config::Runtime;
use Test::Deep;
use Data::Dumper;

my $mockMyAffiliateCFDReport = Test::MockModule->new('BOM::MyAffiliatesCFDReport');

subtest 'New signups csv content' => sub {

    my $processing_date = Date::Utility->new('2023-05-01');

    # Only these users have affiliate tokens and are relevant for the report
    my %users_with_affiliate_token = (
        1 => [['dummy_affiliate_token_1', 'cy']],
        3 => [['dummy_affiliate_token_3', 'cy']],
        4 => [['dummy_affiliate_token_4', 'cy']]);

    my @platforms = ({
            platform           => 'dxtrade',
            account_prefix     => 'DXR',
            account_header     => 'DerivXAccountNumber',
            brand_display_name => 'DerivX'
        },
        {
            platform           => 'ctrader',
            account_prefix     => 'CTR',
            account_header     => 'cTraderAccountNumber',
            brand_display_name => 'cTrader'
        },
    );

    for my $platform (@platforms) {
        my @got_query;
        $mockMyAffiliateCFDReport->mock(
            'db_query',
            sub {
                my ($self, $query, $params) = @_;
                push @got_query, $query;
                if ($query eq 'get_new_signups') {
                    return [
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000001', '1'],
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000002', '2'],
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000003', '3'],
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000004', '4'],
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000005', '5'],
                        ['2023-05-01 12:15', $platform->{account_prefix} . '0000006', '6']];
                } elsif ($query eq 'get_myaffiliate_token_and_residence') {
                    if ($users_with_affiliate_token{$params->{binary_user_id}}) {
                        return $users_with_affiliate_token{$params->{binary_user_id}};
                    }
                }
            });

        my $reporter = BOM::MyAffiliatesCFDReport->new(
            brand              => $platform->{platform},
            platform           => $platform->{platform},
            brand_display_name => $platform->{brand_display_name},
            date               => $processing_date,
        );

        my $results = $reporter->new_registration_csv();
        is $got_query[0], 'get_new_signups', "$platform->{platform}: Correct 'get_new_signups' query executed";
        for (my $i = 1; $i < 7; $i++) {
            is $got_query[$i], 'get_myaffiliate_token_and_residence',
                "$platform->{platform}: Correct 'get_myaffiliate_token_and_residence' query executed";
        }

        my $expected_csv = <<"EOF";
Date,$platform->{account_header},Token,ISOCountry
2023-05-01,$platform->{account_prefix}0000001,dummy_affiliate_token_1,CY
2023-05-01,$platform->{account_prefix}0000003,dummy_affiliate_token_3,CY
2023-05-01,$platform->{account_prefix}0000004,dummy_affiliate_token_4,CY
EOF

        is $results, $expected_csv, "$platform->{platform}: Correct CSV generated";
        $mockMyAffiliateCFDReport->unmock('db_query');
        $reporter = undef;
    }

};

subtest "Trading Activity csv contents" => sub {

    my $processing_date = Date::Utility->new('2023-03-01');

    my @platforms = ({
            platform           => 'dxtrade',
            account_prefix     => 'DXR',
            account_header     => 'DerivXAccountNumber',
            brand_display_name => 'DerivX'
        },
        {
            platform           => 'ctrader',
            account_prefix     => 'CTR',
            account_header     => 'cTraderAccountNumber',
            brand_display_name => 'cTrader'
        },
    );

    for my $platform (@platforms) {
        my @got_loginids;
        my @got_queries;

        my $deposits = {
            $platform->{account_prefix} . '0000001' => [['10.50', '2023-03-01']],
            $platform->{account_prefix} . '0000002' => [['20.35', '2023-03-01']],
            $platform->{account_prefix} . '0000003' => [['300',   '2023-01-03']],
            $platform->{account_prefix} . '0000004' => [['400',   '2023-03-02']],
            $platform->{account_prefix} . '0000005' => [['9999',  '2023-03-01']],
            $platform->{account_prefix} . '0000006' => [['6000',  '2023-03-01']],
            $platform->{account_prefix} . '0000007' => [['7533',  '2023-03-01']]};

        my $binary_user_ids = {
            $platform->{account_prefix} . '0000001' => [[1]],
            $platform->{account_prefix} . '0000002' => [[2]],
            $platform->{account_prefix} . '0000003' => [[3]],
            $platform->{account_prefix} . '0000004' => [[4]],
            $platform->{account_prefix} . '0000005' => [[5]],
            $platform->{account_prefix} . '0000006' => [[6]],
            $platform->{account_prefix} . '0000007' => [[7]],
            $platform->{account_prefix} . '0000008' => [[8]]};

        # Only these users have affiliate tokens and are relevant for the report
        my %users_with_affiliate_token = (
            1 => [['dummy_affiliate_token_1', 'id']],
            3 => [['dummy_affiliate_token_3', 'id']],
            4 => [['dummy_affiliate_token_4', 'br']],
            5 => [['dummy_affiliate_token_5', 'ag']],
            7 => [['dummy_affiliate_token_7', 'ag']],
            8 => [['dummy_affiliate_token_8', 'cu']]);

        my $deals = [
            [$platform->{account_prefix} . '0000001', 'AUD BASKET', 20,     1],
            [$platform->{account_prefix} . '0000001', 'Step',       10000,  1],
            [$platform->{account_prefix} . '0000001', 'EUR/USD',    100,    1],
            [$platform->{account_prefix} . '0000002', 'EUR/AUD',    200000, 1],
            [$platform->{account_prefix} . '0000003', 'AUD/JPY',    350000, 1],
            [$platform->{account_prefix} . '0000003', 'CHF/JPY',    100000, 1],
            [$platform->{account_prefix} . '0000003', 'EUR/USD',    50000,  1],
            [$platform->{account_prefix} . '0000004', 'AUD/JPY',    400000, 1],
            [$platform->{account_prefix} . '0000005', 'Jump 100',   10000,  1],
            [$platform->{account_prefix} . '0000005', 'AAPL',       1000,   1],
            [$platform->{account_prefix} . '0000005', 'DAX 30',     100,    1],
            [$platform->{account_prefix} . '0000005', 'IJR.US',     10,     1],
            [$platform->{account_prefix} . '0000005', 'Vol 100',    1,      1],
            [$platform->{account_prefix} . '0000006', 'AUD/JPY',    500000, 1],
            [$platform->{account_prefix} . '0000006', 'NGAS',       800000, 1],
            [$platform->{account_prefix} . '0000006', 'EUR/NZDm',   45000,  1],
            [$platform->{account_prefix} . '0000006', 'GBP Basket', 2210,   1],
            [$platform->{account_prefix} . '0000008', 'NGAS',       1000,   20]];

        my $contract_sizes = {
            'AUD BASKET' => 10000,
            'Step'       => 10000,
            'EUR/USD'    => 10000,
            'EUR/AUD'    => 10000,
            'AUD/JPY'    => 10000,
            'CHF/JPY'    => 10000,
            'Jump 100'   => 1,
            'AAPL'       => 1,
            'DAX 30'     => 1,
            'IJR.US'     => 1,
            'Vol 100'    => 1,
            'NGAS'       => 1000,
            'EUR/NZDm'   => 1,
            'GBP Basket' => 1
        };

        $mockMyAffiliateCFDReport->mock(
            'db_query',
            sub {
                my ($self, $query, $params) = @_;
                push @got_queries, $query;

                if ($query eq 'get_daily_deposits') {
                    return [
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000001', '10'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000002', '20'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000003', '300'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000004', '400'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000005', '5000'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000006', '6000'],
                        ['2023-03-01 12:15', $platform->{account_prefix} . '0000007', '17271']];
                } elsif ($query eq 'get_first_deposit_and_date') {
                    return $deposits->{$params->{loginid}};
                } elsif ($query eq 'get_binary_user_id') {
                    return $binary_user_ids->{$params->{loginid}};
                } elsif ($query eq 'get_myaffiliate_token_and_residence') {
                    if ($users_with_affiliate_token{$params->{binary_user_id}}) {
                        return $users_with_affiliate_token{$params->{binary_user_id}};
                    }
                } elsif ($query eq 'get_total_volume') {
                    return $deals;
                } elsif ($query eq 'get_symbol_contract_size') {
                    return $contract_sizes->{$params->{symbol}};
                }

            });

        my $reporter = BOM::MyAffiliatesCFDReport->new(
            brand              => $platform->{platform},
            platform           => $platform->{platform},
            brand_display_name => $platform->{brand_display_name},
            date               => $processing_date,
        );

        my @results = split "\n", $reporter->trading_activity_csv();

        my $expected_results = {
            "2023-03-01,$platform->{account_prefix}0000001,1.012,3,10,10.50"  => 1,
            "2023-03-01,$platform->{account_prefix}0000003,50,3,300,0"        => 1,
            "2023-03-01,$platform->{account_prefix}0000004,40,1,400,0"        => 1,
            "2023-03-01,$platform->{account_prefix}0000005,11111,5,5000,9999" => 1,
            "2023-03-01,$platform->{account_prefix}0000008,1,20,0,0"          => 1,
            "2023-03-01,$platform->{account_prefix}0000007,0,0,17271,7533"    => 1,
            "2023-03-01,$platform->{account_prefix}0000002,20,1,0,0"          => 1,
            "2023-03-01,$platform->{account_prefix}0000006,48060,4,0,0"       => 1,
        };

        is $results[0], "Date,$platform->{account_header},DailyVolume,DailyCountOfDeals,DailyBalance,FirstDeposit",
            "$platform->{platform}: Correct csv header";
        for (my $i = 1; $i < scalar(@results); $i++) {
            my $result = $results[$i];
            is $expected_results->{$result}, 1, "Incorrect csv row: $result";
        }

        my @expected_order_of_queries = (
            'get_daily_deposits',                  'get_binary_user_id',
            'get_myaffiliate_token_and_residence', 'get_first_deposit_and_date',
            'get_binary_user_id',                  'get_myaffiliate_token_and_residence',
            'get_binary_user_id',                  'get_myaffiliate_token_and_residence',
            'get_first_deposit_and_date',          'get_binary_user_id',
            'get_myaffiliate_token_and_residence', 'get_first_deposit_and_date',
            'get_binary_user_id',                  'get_myaffiliate_token_and_residence',
            'get_first_deposit_and_date',          'get_binary_user_id',
            'get_myaffiliate_token_and_residence', 'get_binary_user_id',
            'get_myaffiliate_token_and_residence', 'get_first_deposit_and_date',
            'get_total_volume',                    'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size',            'get_symbol_contract_size',
            'get_symbol_contract_size'
        );

        is_deeply \@got_queries, \@expected_order_of_queries, 'Correct order of queries';
        $reporter = undef;
    }
};

subtest "Commission csv contents" => sub {

    my $processing_date = Date::Utility->new('2023-04-01');

    my @platforms = ({
            platform           => 'dxtrade',
            account_prefix     => 'DXR',
            account_header     => 'DerivXAccountNumber',
            brand_display_name => 'DerivX'
        },
        {
            platform           => 'ctrader',
            account_prefix     => 'CTR',
            account_header     => 'cTraderAccountNumber',
            brand_display_name => 'cTrader'
        },
    );

    for my $platform (@platforms) {
        $mockMyAffiliateCFDReport->mock(
            'db_query',
            sub {
                my ($self, $query, $params) = @_;
                if ($query eq 'get_commissions') {
                    return [
                        [$platform->{account_prefix} . '0000001', '10'],
                        [$platform->{account_prefix} . '0000002', '20'],
                        [$platform->{account_prefix} . '0000003', '300'],
                        [$platform->{account_prefix} . '0000004', '400'],
                        [$platform->{account_prefix} . '0000005', '5000'],
                        [$platform->{account_prefix} . '0000006', '0.1542134']];
                }
            });

        my $reporter = BOM::MyAffiliatesCFDReport->new(
            brand              => $platform->{platform},
            platform           => $platform->{platform},
            brand_display_name => $platform->{brand_display_name},
            date               => $processing_date,
        );

        my $results = $reporter->commission_csv();

        my $expected_csv = <<"EOF";
Date,$platform->{account_header},Amount
2023-04-01,$platform->{account_prefix}0000001,10.00
2023-04-01,$platform->{account_prefix}0000002,20.00
2023-04-01,$platform->{account_prefix}0000003,300.00
2023-04-01,$platform->{account_prefix}0000004,400.00
2023-04-01,$platform->{account_prefix}0000005,5000.00
2023-04-01,$platform->{account_prefix}0000006,0.15
EOF

        is $results, $expected_csv, "$platform->{platform}: Correct CSV generated";
        $mockMyAffiliateCFDReport->unmock('db_query');
    }
};

done_testing();
