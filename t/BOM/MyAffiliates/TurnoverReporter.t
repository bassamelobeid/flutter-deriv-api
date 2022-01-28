use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Warnings;
use Date::Utility;
use Format::Util::Numbers qw/financialrounding/;
use List::Util qw(first);

use Brands;

use BOM::MyAffiliates::TurnoverReporter;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Database::DataMapper::FinancialMarketBet;

subtest 'turnover' => sub {
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code        => 'CR',
        myaffiliates_token => 'dummy_affiliate_token',
    });
    my $account = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
        source   => 1,
    );

    my $date       = Date::Utility->new('2017-09-01 00:01:01');
    my $start_date = $date->plus_time_interval('1h')->datetime;
    my $end_date   = $date->plus_time_interval('6h')->datetime;

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type             => 'fmb_higher_lower_sold_won',
        account_id       => $account->id,
        purchase_time    => $start_date,
        transaction_time => $start_date,
        start_time       => $start_date,
        expiry_time      => $end_date,
        settlement_time  => $end_date,
        source           => 1,
    });

    my $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

    my $processing_date = Date::Utility->new('2017-09-01');
    my $reporter        = BOM::MyAffiliates::TurnoverReporter->new(
        brand           => Brands->new(name => 'binary'),
        processing_date => $processing_date,
    );

    is $reporter->output_file_path(), '/db/myaffiliates/binary/turnover_' . $processing_date->date_yyyymmdd . '.csv', 'Output file path is correct';

    my @csv = $reporter->activity();

    ok scalar @csv, 'got some records';

    chomp $csv[0];
    my @header_row = split ',', $csv[0];

    is_deeply([sort @header_row], [qw/Date Loginid PayoutPrice Probability ReferenceId Stake /], 'first row is header row - got correct header');

    my @row = split ',', $csv[1];
    is $row[0], '2017-09-01', 'got correct transaction time';
    is $row[1], $client->loginid, 'got correct loginid';

    ok $row[2], 'has stake price';
    ok $row[3], 'has payout price';
    cmp_ok($row[4], '==', financialrounding('price', 'USD', ($row[2] / $row[3] * 100)), 'got proper probability');
    ok $row[5], 'has reference id';

    cmp_bag($reporter->exclude_broker_codes, ['MF'], 'Correct excluded broker codes');
};

my $broker_code = 'MF';
subtest "turnover $broker_code excluded" => sub {

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code        => $broker_code,
        myaffiliates_token => 'dummy_affiliate_token',
    });
    my $account = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 1000,
        remark   => 'free gift',
        source   => 1,
    );

    my $date       = Date::Utility->new('2017-09-01 00:01:01');
    my $start_date = $date->plus_time_interval('1h')->datetime;
    my $end_date   = $date->plus_time_interval('6h')->datetime;

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type             => 'fmb_higher_lower_sold_won',
        account_id       => $account->id,
        purchase_time    => $start_date,
        transaction_time => $start_date,
        start_time       => $start_date,
        expiry_time      => $end_date,
        settlement_time  => $end_date,
        source           => 1,
    });

    my $bet_mapper = BOM::Database::DataMapper::FinancialMarketBet->new({
        client_loginid => $account->client_loginid,
        currency_code  => $account->currency_code
    });

    my $processing_date = Date::Utility->new('2017-09-01');
    my $reporter        = BOM::MyAffiliates::TurnoverReporter->new(
        brand           => Brands->new(name => 'binary'),
        processing_date => $processing_date,
    );

    is $reporter->output_file_path(), '/db/myaffiliates/binary/turnover_' . $processing_date->date_yyyymmdd . '.csv', 'Output file path is correct';

    my @csv = $reporter->activity();

    ok scalar @csv, 'got some records';

    chomp $csv[0];

    my @header_row = split ',', $csv[0];
    is_deeply([sort @header_row], [qw/Date Loginid PayoutPrice Probability ReferenceId Stake /], 'first row is header row - got correct header');

    my @loginids = ();
    foreach my $row (@csv) {
        my @columns = split ',', $row;

        push @loginids, $reporter->get_broker_code($columns[1]);
    }

    is((first { $_ and $_ eq $broker_code } @loginids), undef, "No $broker_code is in the generate csv");
};

done_testing();
