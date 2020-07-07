#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::Exception;
use Test::MockModule;
use Test::More tests => 3;
use Test::Warn;
use Test::Warnings;

use BOM::User::Client;
use Crypt::NamedKeys;
use Date::Utility;

use BOM::DailySummaryReport;
use BOM::Database::Helper::FinancialMarketBet;
use BOM::User::Password;
use BOM::Config::Runtime;

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Helper::Client qw( create_client top_up );

Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index',    {symbol => 'R_100'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'economic_events',
    {
        events => [{
                symbol       => 'USD',
                release_date => 1,
                source       => 'forexfactory',
                impact       => 1,
                event_name   => 'FOMC',
            }]});

my $today    = Date::Utility->new->truncate_to_day;
my $next_day = $today->plus_time_interval('1d');
foreach my $date ($today, $next_day) {
    my @epochs = map { $date->epoch + $_ } (-2, -1, 0, 1, 2, 3, 4);
    map { BOM::Test::Data::Utility::FeedTestDatabase::create_tick({underlying => 'R_100', epoch => $_, quote => 100}) } @epochs;
}

my $cr = create_client('CR');
top_up($cr, 'USD', 5000);
my $acc_usd    = $cr->account;
my $mocked_dsr = Test::MockModule->new('BOM::DailySummaryReport');
$mocked_dsr->mock(
    'get_client_details',
    sub {
        return {
            $cr->loginid => {
                'account_id'  => $acc_usd->id,
                'balance_at'  => 5000.00,
                'deposits'    => 5000.00,
                'loginid'     => $cr->loginid,
                'withdrawals' => 0,
            },
        };
    });

subtest 'skip if it dies' => sub {
    # buys one bet on a different date
    buy_one_bet(
        $acc_usd,
        {
            bet_type  => 'CALL',
            barrier   => 'S0P',
            bet_class => 'higher_lower_bet',
            shortcode => 'wrong_shortcode'
        });
    lives_ok {
        my $total_pl;
        warning_like {
            $total_pl = BOM::DailySummaryReport->new(
                for_date    => Date::Utility->new->date_yyyymmdd,
                currencies  => ['USD'],
                brokercodes => ['CR'],
                broker_path => BOM::Config::Runtime->instance->app_config->system->directory->db . '/f_broker/',
                save_file   => 0,
            )->generate_report;
        }
        [qr/^bid price error/], "Expected warning is thrown";
        cmp_ok $total_pl->{CR}->{USD}, '==', 0;
    }
    'skip if it dies';
};

subtest 'successful run' => sub {
    my %contracts = (
        CALL => {
            barrier   => 'S0P',
            bet_class => 'higher_lower_bet'
        },
        PUT => {
            barrier   => 'S0P',
            bet_class => 'higher_lower_bet'
        },
        ONETOUCH => {
            barrier   => 'S100P',
            bet_class => 'touch_bet'
        },
        NOTOUCH => {
            barrier   => 'S-99P',
            bet_class => 'touch_bet'
        },
    );
    # buy all valid contracts
    foreach my $type (keys %contracts) {
        buy_one_bet(
            $acc_usd,
            {
                bet_type   => $type,
                start_time => $next_day,
                %{$contracts{$type}}});
    }

    lives_ok {
        my $total_pl;
        warning_like {
            $total_pl = BOM::DailySummaryReport->new(
                for_date    => $next_day->date_yyyymmdd,
                currencies  => ['USD'],
                brokercodes => ['CR'],
                broker_path => BOM::Config::Runtime->instance->app_config->system->directory->db . '/f_broker/',
                save_file   => 0,
            )->generate_report;
        }
        [qr/^bid price error/], "Expected warning is thrown";
        my @brokers = keys %$total_pl;
        ok @brokers, 'has element';
        cmp_ok scalar @brokers, '==', 1;
        ok exists $total_pl->{CR};
        ok exists $total_pl->{CR}->{USD};
        cmp_ok $total_pl->{CR}->{USD}, '>', 0;
    }
    'generate daily summary report';
};

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

sub buy_one_bet {
    my ($acc, $args) = @_;

    my $now =
          $args->{start_time}
        ? $args->{start_time}->truncate_to_day->minus_time_interval('1s')
        : Date::Utility->new->truncate_to_day->minus_time_interval('1s');
    my $buy_price        = delete $args->{buy_price}        // 20;
    my $payout_price     = delete $args->{payout_price}     // $buy_price * 10;
    my $limits           = delete $args->{limits};
    my $duration         = delete $args->{duration}         // '30d';
    my $relative_barrier = delete $args->{relative_barrier} // 'S0P';
    my $bet_class        = delete $args->{bet_class};
    my $shortcode        = delete $args->{shortcode}        // $args->{bet_type}
        . '_R_100_'
        . $payout_price . '_'
        . $now->epoch . '_'
        . $now->plus_time_interval($duration)->epoch . '_'
        . $relative_barrier . '_0';

    my $bet_data = +{
        underlying_symbol => 'R_100',
        payout_price      => $payout_price,
        buy_price         => $buy_price,
        remark            => 'Test Remark',
        purchase_time     => $now->db_timestamp,
        start_time        => $now->db_timestamp,
        expiry_time       => $now->plus_time_interval($duration)->db_timestamp,
        settlement_time   => $now->plus_time_interval($duration)->db_timestamp,
        is_expired        => 1,
        is_sold           => 0,
        bet_class         => $bet_class,
        bet_type          => $args->{bet_type},
        short_code        => $shortcode,
        relative_barrier  => $relative_barrier,
        quantity          => 1,
    };

    my $fmb = BOM::Database::Helper::FinancialMarketBet->new({
            bet_data     => $bet_data,
            account_data => {
                client_loginid => $acc->client_loginid,
                currency_code  => $acc->currency_code
            },
            limits => $limits,
            db     => db,
        });
    my ($bet, $txn) = $fmb->buy_bet;
    # note explain [$bet, $txn];
    return ($txn->{id}, $bet->{id}, $txn->{balance_after});
}

