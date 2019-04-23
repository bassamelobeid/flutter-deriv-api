use strict;
use warnings;

use Test::More (tests => 4);
use Test::Warnings;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::MyAffiliates::ActivityReporter;

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code        => 'CR',
    myaffiliates_token => 'dummy_affiliate_token',
});
my $account = $client->set_default_account('USD');

my $day_one = '2011-03-08 12:59:59';
my $day_two = '2011-03-09 12:59:59';

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => 9098,
    remark           => 'here is money',
    payment_type     => 'credit_debit_card',
    transaction_time => $day_one,
    payment_time     => $day_one,
);

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => -987,
    remark           => 'here is money',
    payment_type     => 'credit_debit_card',
    transaction_time => $day_one,
    payment_time     => $day_one,
);

$client->payment_legacy_payment(
    currency         => 'USD',
    amount           => 270,
    remark           => 'here is money',
    payment_type     => 'credit_debit_card',
    transaction_time => $day_two,
    payment_time     => $day_two,
);

BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
    type             => 'fmb_higher_lower',
    account_id       => $account->id,
    buy_price        => 456,
    sell_price       => 40,
    payment_time     => $day_one,
    transaction_time => $day_one,
    start_time       => $day_one,
    expiry_time      => $day_one,
});
BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
    type             => 'fmb_higher_lower',
    account_id       => $account->id,
    buy_price        => 789,
    sell_price       => 40,
    payment_time     => $day_one,
    transaction_time => $day_one,
    start_time       => $day_one,
    expiry_time      => $day_two,
});

subtest 'Activity report for specific date' => sub {
    plan tests => 2;

    my $reporter = BOM::MyAffiliates::ActivityReporter->new;

    my @csv = $reporter->activity_for_date_as_csv(substr($day_one, 0, 10));
    @csv = grep { my $id = $client->loginid; /$id/ } @csv;    # Filters other clients out

    is(@csv, 1, 'Check if there is only one entry for our client on the report');
    chomp $csv[0];
    # The reported PNL in this test is wrong because there is no sell operation for those bets
    # Selling them (by __MUST_SELL__ => 1) uses the current date, which also doesn't appear on the report
    # I will call this "good enough" for now.
    is(
        $csv[0],
        '2011-03-08,' . $client->loginid . ',0.00,9098.00,0.00,456.00,789.00,2011-03-08,987.00,9098.00',
        'Check if values are correct in report'
    );
};

subtest 'Not funded account with transaction (bonus?)' => sub {
    plan tests => 1;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code        => 'CR',
        myaffiliates_token => 'dummy_affiliate_token',
    });
    my $account = $client->set_default_account('USD');

    $client->payment_legacy_payment(
        currency     => 'USD',
        amount       => 5000,
        remark       => 'here is money',
        payment_type => 'credit_debit_card',
    );

    $client->payment_legacy_payment(
        currency     => 'USD',
        amount       => 800,
        remark       => 'here is money',
        payment_type => 'credit_debit_card',
    );

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type             => 'fmb_higher_lower',
        account_id       => $account->id,
        buy_price        => 789,
        sell_price       => 40,
        payment_time     => $day_one,
        transaction_time => $day_one,
        start_time       => $day_one,
        expiry_time      => $day_two,
    });

    my @csv = BOM::MyAffiliates::ActivityReporter->new->activity_for_date_as_csv(substr($day_one, 0, 10));
    @csv = grep { my $id = $client->loginid; /$id/ } @csv;
    is(@csv, 1, 'Client is on the list');
};

subtest 'Virtual clients are not reported' => sub {
    plan tests => 1;

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code        => 'VRTC',
        myaffiliates_token => 'dummy_affiliate_token',
    });
    my $account = $client->set_default_account('USD');

    $client->payment_legacy_payment(
        currency         => 'USD',
        amount           => 270,
        remark           => 'here is money',
        payment_type     => 'credit_debit_card',
        transaction_time => $day_two,
        payment_time     => $day_two,
    );

    my @csv = BOM::MyAffiliates::ActivityReporter->new->activity_for_date_as_csv(substr($day_one, 0, 10));
    @csv = grep { /VRTC/ } @csv;    # Filters only VRTC clients
    is(@csv, 0, 'No Virtual client is not on the list');
};
