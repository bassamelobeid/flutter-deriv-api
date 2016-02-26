use strict;
use warnings;

use Test::More qw( no_plan );
use Test::Exception;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);

use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Date::Utility;
use BOM::Market::Underlying;
use BOM::RiskReporting::MarkedToModel;
use BOM::Platform::Runtime;
use BOM::Database::DataMapper::CollectorReporting;

initialize_realtime_ticks_db();

my $now        = Date::Utility->new;
my $plus5mins  = Date::Utility->new(time + 300);
my $plus30mins = Date::Utility->new(time + 1800);
my $minus5mins = Date::Utility->new(time - 300);

my %date_string = (
    R_50      => [$minus5mins->datetime, $now->datetime, $plus5mins->datetime],
    frxEURCHF => [$minus5mins->datetime, $now->datetime, $plus5mins->datetime],
    frxUSDJPY => ['21-Sep-05 06h50GMT', '21-Sep-05 07h00GMT', '21-Sep-05 07h20GMT', '10-May-09 11h00GMT'],
    frxEURUSD => ['3-Jan-06 10h20GMT',  '27-Apr-09 06h02GMT', '10-May-09 11h00GMT'],
    frxAUDJPY => ['10-May-09 11h00GMT', '5-Nov-09 14h00GMT',  '9-Nov-09 11h00GMT'],
);

foreach my $symbol (keys %date_string) {
    my @dates = @{$date_string{$symbol}};
    foreach my $date (@dates) {
        $date = Date::Utility->new($date);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick(
            {
                underlying => $symbol,
                epoch      => $date->epoch,
                quote      => 100
            });
    }
}

subtest 'realtime report generation' => sub {
    plan tests => 3;

    my $dm = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
    });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $USDaccount = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency    => 'USD',
        amount      => 5000,
        remark      => 'free gift',
    );

    my $start_time  = $minus5mins;
    my $expiry_time = $now;

    my %bet_hash = (
        bet_type          => 'FLASHU',
        relative_barrier  => 'S0P',
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 100,
        buy_price         => 53,
        purchase_time     => $start_time->datetime_yyyymmdd_hhmmss,
        start_time        => $start_time->datetime_yyyymmdd_hhmmss,
        expiry_time       => $expiry_time->datetime_yyyymmdd_hhmmss,
        settlement_time   => $expiry_time->datetime_yyyymmdd_hhmmss,
    );

    my @shortcode_param = (
        $bet_hash{bet_type}, $bet_hash{underlying_symbol},
        $bet_hash{payout_price}, $start_time->epoch, $expiry_time->epoch, $bet_hash{relative_barrier}, 0
    );

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type => 'fmb_higher_lower',
        %bet_hash,
        account_id => $USDaccount->id,
        short_code => uc join('_', @shortcode_param),
    });

    $start_time  = $now;
    $expiry_time = $plus5mins;
    %bet_hash    = (
        bet_type          => 'FLASHU',
        relative_barrier  => 'S0P',
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 101,
        buy_price         => 52,
        purchase_time     => $start_time->datetime_yyyymmdd_hhmmss,
        start_time        => $start_time->datetime_yyyymmdd_hhmmss,
        expiry_time       => $expiry_time->datetime_yyyymmdd_hhmmss,
        settlement_time   => $expiry_time->datetime_yyyymmdd_hhmmss,
    );

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type => 'fmb_higher_lower',
        %bet_hash,
        account_id => $USDaccount->id,
        short_code => uc join('_', @shortcode_param),
    });

    $start_time  = $plus5mins;
    $expiry_time = $plus30mins;
    %bet_hash    = (
        bet_type          => 'FLASHU',
        relative_barrier  => 'S0P',
        underlying_symbol => 'frxUSDJPY',
        payout_price      => 101,
        buy_price         => 52,
        purchase_time     => $start_time->datetime_yyyymmdd_hhmmss,
        start_time        => $start_time->datetime_yyyymmdd_hhmmss,
        expiry_time       => $expiry_time->datetime_yyyymmdd_hhmmss,
        settlement_time   => $expiry_time->datetime_yyyymmdd_hhmmss,
    );

    BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
        type => 'fmb_higher_lower',
        %bet_hash,
        account_id => $USDaccount->id,
        short_code => uc join('_', @shortcode_param),
    });

    is($dm->get_last_generated_historical_marked_to_market_time, undef, 'Start with a clean slate.');

    my $results;
    lives_ok { $results = BOM::RiskReporting::MarkedToModel->new(end => $now, send_alerts => 0)->generate } 'Report generation does not die.';

    note 'This may not be checking what you think.  It can not tell when things sold.';
    is($dm->get_last_generated_historical_marked_to_market_time, $now->db_timestamp, 'It ran and updated our timestamp.');
    note "Includes a lot of unit test transactions about which we don't care.";
};

