#!/etc/rmg/bin/perl
use strict;
use warnings;

use Test::More;
use Test::Exception;
use Test::MockModule;
use Test::Warnings qw/warning/;
use File::Spec;
use Path::Tiny;

use Email::Address::UseXS;
use BOM::Test::Email qw/mailbox_clear mailbox_search/;
use BOM::Test::Data::Utility::UnitTestCollectorDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::ExchangeRates qw/populate_exchange_rates/;
use Date::Utility;
use BOM::MarketData::Types;
use BOM::RiskReporting::MarkedToModel;
use BOM::Config::Runtime;
use BOM::Database::DataMapper::CollectorReporting;

my $now         = Date::Utility->new(time);
my $minus16secs = Date::Utility->new(time - 16);
my $minus6mins  = Date::Utility->new(time - 360);
my $minus5mins  = Date::Utility->new(time - 300);
my $plus1day    = Date::Utility->new(time + 24 * 60 * 60);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        recorded_date => $minus16secs,
        symbol        => $_,
    }) for qw( EUR GBP XAU USD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $minus16secs
    }) for qw (frxEURCHF frxUSDJPY frxEURUSD frxAUDJPY);

my $test_symbol = ($now->day_of_week > 0 and $now->day_of_week < 6) ? 'frxUSDJPY' : 'R_100';
my %date_string = (
    $test_symbol => [$minus5mins->datetime, $minus16secs->datetime],
);

initialize_realtime_ticks_db();

my %rates = map { $_ => 100 } ('BCH', 'EUR', 'BTC', 'GBP', 'LTC', 'ETH', 'AUD', 'JPY', 'UST', 'USB', 'IDK');
populate_exchange_rates(\%rates);

foreach my $symbol (keys %date_string) {
    my @dates = @{$date_string{$symbol}};
    foreach my $date (@dates) {
        $date = Date::Utility->new($date);
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $date->epoch,
            quote      => 100
        });
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => $symbol,
            epoch      => $date->epoch + 2,
            quote      => 100
        });

    }
}

subtest 'realtime report generation' => sub {
    plan tests => 11;

    mailbox_clear();

    my $dm = BOM::Database::DataMapper::CollectorReporting->new({
        broker_code => 'FOG',
    });

    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
        broker_code => 'CR',
    });
    my $USDaccount = $client->set_default_account('USD');

    $client->payment_free_gift(
        currency => 'USD',
        amount   => 5000,
        remark   => 'free gift',
    );

    my @times = (
        [$minus5mins,  $minus16secs],    # 0 contracts that expired more than 15 seconds
        [$minus5mins,  $minus16secs],    # 1 contracts that expired more than 15 seconds
        [$minus6mins,  $minus16secs],    # 2 contracts that be used to simulate error
        [$minus5mins,  $now],            # 3 contracts that expired less than 15 seconds
        [$minus16secs, $plus1day],       # 4 contracts that not expired
    );
    my ($contract_ok1_index, $contract_ok2_index, $contract_error_index, $contract_just_expired_index, $contract_not_expired) = (0 .. $#times);

    my @fmbs;
    for my $t (@times) {
        my ($start_time, $expiry_time) = @$t;
        my %bet_hash = (
            bet_type          => 'CALL',
            relative_barrier  => 'S0P',
            underlying_symbol => $test_symbol,
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
        my $short_code = uc join('_', @shortcode_param);
        my $fmb = BOM::Test::Data::Utility::UnitTestDatabase::create_fmb({
            type => 'fmb_higher_lower',
            %bet_hash,
            account_id => $USDaccount->id,
            short_code => $short_code,
        });
        my $fmb_info = {
            fmb_id     => $fmb->id,
            short_code => $short_code,
        };
        push @fmbs, $fmb_info;
    }

    is($dm->get_last_generated_historical_marked_to_market_time, undef, 'Start with a clean slate.');

    my $short_code         = $fmbs[$contract_error_index]{short_code};
    my $mocked_transaction = Test::MockModule->new('BOM::Transaction');
    my $called_count       = 0;
    $mocked_transaction->mock(
        'sell_expired_contracts' => sub {
            $called_count++;
            $mocked_transaction->mock(
                'produce_contract',
                sub {
                    if ($_[0]->{shortcode} eq $short_code) {
                        die "error";
                    }
                    $mocked_transaction->original('produce_contract')->(@_);
                });

            my $result = $mocked_transaction->original('sell_expired_contracts')->(@_);
            $mocked_transaction->unmock('produce_contract');
            return $result;
        });
    #mock on_production to test email
    my $mocked_system = Test::MockModule->new('BOM::Config');
    $mocked_system->mock('on_production', sub { 1 });

    my $results;
    warning {
        lives_ok { $results = BOM::RiskReporting::MarkedToModel->new(end => $now, send_alerts => 0)->generate } 'Report generation does not die.';
    };

    note 'This may not be checking what you think.  It can not tell when things sold.';
    is($dm->get_last_generated_historical_marked_to_market_time, $now->db_timestamp, 'It ran and updated our timestamp.');
    note "Includes a lot of unit test transactions about which we don't care.";
    is($called_count, 1, 'BOM::Transaction::sell_expired_contracts called only once');

    my @msgs = mailbox_search(
        email   => 'quants-market-data@regentmarkets.com',
        subject => qr/AutoSell Failures/,
        body    => qr/Shortcode:/,
    );

    ok(@msgs, "find the email");
    my @errors = $msgs[0]{body};
    is(scalar @errors, 1, "number of contracts that have errors ");

    my @is_sold = (1, 1, 0, 0, 0);
    for my $index (0 .. $#fmbs) {
        my $fmb = BOM::Database::DataMapper::FinancialMarketBet->new({broker_code => $client->broker})->get_fmb_by_id([$fmbs[$index]{fmb_id}])->[0]
            ->financial_market_bet_record;
        my $is_sold = $fmb->is_sold // 0;
        is($is_sold, $is_sold[$index], "fmb $fmbs[$index]{fmb_id} is_sold value should be $is_sold[$index]");
    }
    done_testing;
};
done_testing;

