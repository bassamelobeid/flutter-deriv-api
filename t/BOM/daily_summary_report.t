#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;

use BOM::DailySummaryReport;
use BOM::Platform::Runtime;
use Date::Utility;
use BOM::Database::Helper::FinancialMarketBet;

use BOM::Platform::Client::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Crypt::NamedKeys;
Crypt::NamedKeys::keyfile '/etc/rmg/aes_keys.yml';

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => 'USD'});
BOM::Test::Data::Utility::UnitTestMarketData::create_doc('index',    {symbol => 'R_100'});

my $today    = Date::Utility->new->truncate_to_day;
my $next_day = $today->plus_time_interval('1d');
foreach my $date ($today, $next_day) {
    my @epochs = map { $date->epoch + $_ } (-2, -1, 0, 1, 2, 3, 4);
    map { BOM::Test::Data::Utility::FeedTestDatabase::create_tick({underlying => 'R_100', epoch => $_, quote => 100}) } @epochs;
}

my $cr = create_client('CR');
top_up($cr, 'USD', 5000);
my $acc_usd = $cr->find_account(query => [currency_code => 'USD'])->[0];
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
        my $total_pl = BOM::DailySummaryReport->new(
            for_date    => Date::Utility->new->date_yyyymmdd,
            currencies  => ['USD'],
            brokercodes => ['CR'],
            broker_path => BOM::Platform::Runtime->instance->app_config->system->directory->db . '/f_broker/',
            save_file   => 0,
        )->generate_report;
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
        SPREADU => 1,
        SPREADD => 1,
    );
    # buy all valid contracts
    foreach my $type (keys %contracts) {
        if ($type eq 'SPREADU' or $type eq 'SPREADD') {
            buy_one_spread_bet(
                $acc_usd,
                {
                    bet_type   => $type,
                    start_time => $next_day
                });
        } else {
            buy_one_bet(
                $acc_usd,
                {
                    bet_type   => $type,
                    start_time => $next_day,
                    %{$contracts{$type}}});
        }
    }

    lives_ok {
        my $total_pl = BOM::DailySummaryReport->new(
            for_date    => $next_day->date_yyyymmdd,
            currencies  => ['USD'],
            brokercodes => ['CR'],
            broker_path => BOM::Platform::Runtime->instance->app_config->system->directory->db . '/f_broker/',
            save_file   => 0,
        )->generate_report;
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

sub buy_one_spread_bet {
    my ($acc, $args) = @_;

    my $now =
          $args->{start_time}
        ? $args->{start_time}->truncate_to_day->minus_time_interval('1s')
        : Date::Utility->new->truncate_to_day->minus_time_interval('1s');
    my $buy_price      = delete $args->{buy_price} // 20;
    my $limits         = delete $args->{limits};
    my $app            = delete $args->{amount_per_point} // 2;
    my $stop_type      = delete $args->{stop_type} // 'point';
    my $stop_loss      = delete $args->{stop_loss} // 10;
    my $stop_profit    = delete $args->{stop_profit} // 10;
    my $spread         = delete $args->{spread} // 2;
    my $spread_divisor = delete $args->{spread_divisor} // 1;

    my $bet_data = +{
        underlying_symbol => 'R_100',
        buy_price         => $buy_price,
        remark            => 'Test Remark',
        purchase_time     => $now->db_timestamp,
        start_time        => $now->db_timestamp,
        expiry_time       => $now->plus_time_interval('365d')->db_timestamp,
        settlement_time   => $now->plus_time_interval('365d')->db_timestamp,
        is_expired        => 0,
        is_sold           => 0,
        bet_class         => 'spread_bet',
        bet_type          => $args->{bet_type},
        short_code        => ($args->{bet_type} . '_R_100_' . $app . '_' . $now->epoch . '_' . $stop_loss . '_' . $stop_profit . '_' . uc $stop_type),
        amount_per_point  => $app,
        stop_type         => $stop_type,
        stop_profit       => $stop_profit,
        stop_loss         => $stop_loss,
        spread_divisor    => $spread_divisor,
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

sub top_up {
    my ($c, $cur, $amount) = @_;

    my @acc = $c->account;
    if (@acc) {
        @acc = grep { $_->currency_code eq $cur } @acc;
        @acc = $c->add_account({
                currency_code => $cur,
                is_default    => 0
            }) unless @acc;
    } else {
        @acc = $c->add_account({
            currency_code => $cur,
            is_default    => 1
        });
    }

    my $acc = $acc[0];
    unless (defined $acc->id) {
        $acc->save;
        note 'Created account ' . $acc->id . ' for ' . $c->loginid . ' segment ' . $cur;
    }

    my ($pm) = $acc->add_payment({
        amount               => $amount,
        payment_gateway_code => "legacy_payment",
        payment_type_code    => "ewallet",
        status               => "OK",
        staff_loginid        => "test",
        remark               => __FILE__ . ':' . __LINE__,
    });
    $pm->legacy_payment({legacy_type => "ewallet"});
    my ($trx) = $pm->add_transaction({
        account_id    => $acc->id,
        amount        => $amount,
        staff_loginid => "test",
        remark        => __FILE__ . ':' . __LINE__,
        referrer_type => "payment",
        action_type   => ($amount > 0 ? "deposit" : "withdrawal"),
        quantity      => 1,
    });
    $acc->save(cascade => 1);
    $trx->load;    # to re-read (get balance_after)

    note $c->loginid . "'s balance is now $cur " . $trx->balance_after . "\n";
}

sub create_client {
    my $broker = shift;
    return BOM::Platform::Client->register_and_return_new_client({
        broker_code      => $broker,
        client_password  => BOM::System::Password::hashpw('12345678'),
        salutation       => 'Ms',
        last_name        => 'Doe',
        first_name       => 'Jane' . time . '.' . int(rand 1000000000),
        email            => 'jane.doe' . time . '.' . int(rand 1000000000) . '@test.domain.nowhere',
        residence        => 'in',
        address_line_1   => '298b md rd',
        address_line_2   => '',
        address_city     => 'Place',
        address_postcode => '65432',
        address_state    => 'st',
        phone            => '+9145257468',
        secret_question  => 'What the f***?',
        secret_answer    => BOM::Platform::Client::Utility::encrypt_secret_answer('is that'),
        date_of_birth    => '1945-08-06',
    });
}

