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

    my @got_query;
    $mockMyAffiliateCFDReport->mock(
        'db_query',
        sub {
            my ($self, $query, $params) = @_;
            push @got_query, $query;
            if ($query eq 'get_new_signups') {
                return [
                    ['2023-05-01 12:15', 'DXR0000001', '1'],
                    ['2023-05-01 12:15', 'DXR0000002', '2'],
                    ['2023-05-01 12:15', 'DXR0000003', '3'],
                    ['2023-05-01 12:15', 'DXR0000004', '4'],
                    ['2023-05-01 12:15', 'DXR0000005', '5'],
                    ['2023-05-01 12:15', 'DXR0000006', '6']];
            } elsif ($query eq 'get_myaffiliate_token_and_residence') {
                if ($users_with_affiliate_token{$params->{binary_user_id}}) {
                    return $users_with_affiliate_token{$params->{binary_user_id}};
                }
            }
        });

    my $reporter = BOM::MyAffiliatesCFDReport->new(
        brand              => 'derivx',
        platform           => 'dxtrade',
        brand_display_name => 'DerivX',
        date               => $processing_date,
    );

    my $results = $reporter->new_registration_csv();
    is $got_query[0], 'get_new_signups', "Correct query executed";
    for (my $i = 1; $i < 7; $i++) {
        is $got_query[$i], 'get_myaffiliate_token_and_residence', "Correct query executed";
    }

    my $expected_csv = <<'EOF';
Date,DerivXAccountNumber,Token,ISOCountry
2023-05-01,DXR0000001,dummy_affiliate_token_1,CY
2023-05-01,DXR0000003,dummy_affiliate_token_3,CY
2023-05-01,DXR0000004,dummy_affiliate_token_4,CY
EOF

    is $results, $expected_csv, 'Correct CSV generated';
    $mockMyAffiliateCFDReport->unmock('db_query');

};

subtest "Trading Activity csv contents" => sub {

    my $processing_date = Date::Utility->new('2023-03-01');
    my @got_loginids;
    my @got_queries;

    my $deposits = {
        'DXR0000001' => [['10.50', '2023-03-01']],
        'DXR0000002' => [['20.35', '2023-03-01']],
        'DXR0000003' => [['300',   '2023-01-03']],
        'DXR0000004' => [['400',   '2023-03-02']],
        'DXR0000005' => [['9999',  '2023-03-01']],
        'DXR0000006' => [['6000',  '2023-03-01']]};

    my $binary_user_ids = {
        'DXR0000001' => [[1]],
        'DXR0000002' => [[2]],
        'DXR0000003' => [[3]],
        'DXR0000004' => [[4]],
        'DXR0000005' => [[5]],
        'DXR0000006' => [[6]]};

    # Only these users have affiliate tokens and are relevant for the report
    my %users_with_affiliate_token = (
        1 => [['dummy_affiliate_token_1', 'id']],
        3 => [['dummy_affiliate_token_3', 'id']],
        4 => [['dummy_affiliate_token_4', 'br']],
        5 => [['dummy_affiliate_token_5', 'ag']]);

    my $deals = {
        'DXR0000001' => [['AUD BASKET', 20], ['Step', 10000], ['EUR/USD', 100]],
        'DXR0000002' => [['EUR/AUD',    200000]],
        'DXR0000003' => [['AUD/JPY',    350000], ['CHF/JPY', 100000], ['EUR/USD', 50000]],
        'DXR0000004' => [['AUD/JPY',    400000]],
        'DXR0000005' => [['Jump 100', 10000], ['AAPL', 1000], ['DAX 30', 100], ['IJR.US', 10], ['Vol 100', 1]],
        'DXR0000006' => [['AUD/JPY', 500000], ['NGAS', 800000], ['EUR/NZDm', 45000], ['GBP Basket', 2210]]};

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
                    ['2023-05-01 12:15', 'DXR0000001', '10'],
                    ['2023-05-01 12:15', 'DXR0000002', '20'],
                    ['2023-05-01 12:15', 'DXR0000003', '300'],
                    ['2023-05-01 12:15', 'DXR0000004', '400'],
                    ['2023-05-01 12:15', 'DXR0000005', '5000'],
                    ['2023-05-01 12:15', 'DXR0000006', '6000']];
            } elsif ($query eq 'get_first_deposit_and_date') {
                return $deposits->{$params->{loginid}};
            } elsif ($query eq 'get_binary_user_id') {
                return $binary_user_ids->{$params->{loginid}};
            } elsif ($query eq 'get_myaffiliate_token_and_residence') {
                if ($users_with_affiliate_token{$params->{binary_user_id}}) {
                    return [$users_with_affiliate_token{$params->{binary_user_id}}, 'cy'];
                }
            } elsif ($query eq 'get_total_volume') {
                return $deals->{$params->{loginid}};
            } elsif ($query eq 'get_symbol_contract_size') {
                return $contract_sizes->{$params->{symbol}};
            }

        });

    my $reporter = BOM::MyAffiliatesCFDReport->new(
        brand              => 'derivx',
        platform           => 'dxtrade',
        brand_display_name => 'DerivX',
        date               => $processing_date,
    );

    my $results = $reporter->trading_activity_csv();

    my $expected_results = <<'EOF';
Date,DerivXAccountNumber,DailyVolume,DailyCountOfDeals,DailyBalance,FirstDeposit
2023-03-01,DXR0000001,1.012,3,10,10.50
2023-03-01,DXR0000003,50,3,300,0
2023-03-01,DXR0000004,40,1,400,0
2023-03-01,DXR0000005,11111,5,5000,9999
EOF

    is $results, $expected_results, 'Correct csv contents';

    my @expected_order_of_queries = (
        'get_daily_deposits',
        'get_first_deposit_and_date',    # DXR0000001
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence',
        'get_total_volume',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_first_deposit_and_date',    # DXR0000002
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence',
        'get_first_deposit_and_date',    # DXR0000003
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence',
        'get_total_volume',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_first_deposit_and_date',    # DXR0000004
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence',
        'get_total_volume',
        'get_symbol_contract_size',
        'get_first_deposit_and_date',    # DXR0000005
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence',
        'get_total_volume',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_symbol_contract_size',
        'get_first_deposit_and_date',    # DXR0000006
        'get_binary_user_id',
        'get_myaffiliate_token_and_residence'
    );

    is_deeply \@got_queries, \@expected_order_of_queries, 'Correct order of queries';

};

subtest "Commission csv contents" => sub {

    my $processing_date = Date::Utility->new('2023-04-01');
    $mockMyAffiliateCFDReport->mock(
        'db_query',
        sub {
            my ($self, $query, $params) = @_;
            if ($query eq 'get_commissions') {
                return [
                    ['DXR0000001', '10'],
                    ['DXR0000002', '20'],
                    ['DXR0000003', '300'],
                    ['DXR0000004', '400'],
                    ['DXR0000005', '5000'],
                    ['DXR0000006', '6000']];
            }
        });

    my $reporter = BOM::MyAffiliatesCFDReport->new(
        brand              => 'derivx',
        platform           => 'dxtrade',
        brand_display_name => 'DerivX',
        date               => $processing_date,
    );

    my $results = $reporter->commission_csv();

    my $expected_csv = <<'EOF';
Date,DerivXAccountNumber,Amount
2023-04-01,DXR0000001,10
2023-04-01,DXR0000002,20
2023-04-01,DXR0000003,300
2023-04-01,DXR0000004,400
2023-04-01,DXR0000005,5000
2023-04-01,DXR0000006,6000
EOF

    is $results, $expected_csv, 'Correct CSV generated';
    $mockMyAffiliateCFDReport->unmock('db_query');

};

done_testing();

