#!perl

use strict;
use warnings;

use Test::More;
use Test::MockModule;
use Test::MockTime qw(set_fixed_time restore_time);
use Test::Exception;
use Test::Mojo;

use BOM::User::Client;

use BOM::Database::ClientDB;
use BOM::Database::DataMapper::Copier;
use BOM::Platform::Client::IDAuthentication;
use BOM::Platform::Copier;
use BOM::User::Password;
use BOM::Product::ContractFactory qw( produce_contract );

use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Helper::Client qw( create_client top_up );
use BOM::Test::RPC::Client;

use Test::BOM::RPC::Contract;
use Email::Stuffer::TestLinks;

my %default_call_params = (
    client_ip  => '127.0.0.1',
    user_agent => '12_copiers.t',
    language   => 'EN',
);

Crypt::NamedKeys->keyfile('/etc/rmg/aes_keys.yml');
my $mock_rpc = Test::MockModule->new('BOM::Transaction::Validation');
$mock_rpc->mock(_validate_tnc => sub { note "mocked BOM::Transaction::Validation->validate_tnc returning nothing"; undef });

sub db {
    return BOM::Database::ClientDB->new({
            broker_code => 'CR',
        })->db;
}

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
my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

####################################################################
# Setup clients
####################################################################

my $trader_CR   = create_client('CR',   0, {email => 'trader_cr@binary.com'});
my $copier_CR   = create_client('CR',   0, {email => 'copier_cr@binary.com'});
my $trader_VRTC = create_client('VRTC', 0, {email => 'trader_vrtc@binary.com'});
my $copier_VRTC = create_client('VRTC', 0, {email => 'copier_vrtc@binary.com'});
my $copier_MLT  = create_client('MLT',  0, {email => 'copier_mlt@binary.com'});
my $copier_MF   = create_client('MLT',  0, {email => 'copier_mf@binary.com'});
my $EUR_copier  = create_client('CR');
my $unset_trader = create_client('CR');
my $CR_client = create_client('CR', 0, {email => 'client@binary.com'});

my %tokens;
for ($trader_CR, $copier_CR, $trader_VRTC, $copier_VRTC, $copier_MLT, $copier_MF, $EUR_copier, $unset_trader, $CR_client) {
    $tokens{$_->loginid} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $_->loginid);
}

set_allow_copiers($trader_CR);
set_allow_copiers($trader_VRTC);

####################################################################
# Tests begin here
####################################################################

####################################################################
# Test valid copy-trade pairs
####################################################################

my @valid_test_pairs = ([$trader_CR, $copier_CR], [$trader_VRTC, $copier_VRTC],);

foreach my $pair (@valid_test_pairs) {
    my $test_name = join(' ', 'Valid Pair | Trader:', $pair->[0]->loginid, 'Copier:', $pair->[1]->loginid);
    subtest $test_name => sub {
        copy_trading_test_routine($pair->[0], $pair->[1]);
    };

}

####################################################################
# Test Invalid copy-trade pairs
####################################################################

my @invalid_test_pairs = (
    [$trader_CR,   $copier_VRTC],
    [$trader_CR,   $copier_MLT],
    [$trader_CR,   $copier_MF],
    [$trader_VRTC, $copier_CR],
    [$trader_VRTC, $copier_MLT],
    [$trader_VRTC, $copier_MF],
);

foreach my $pair (@invalid_test_pairs) {
    my $test_name    = join(' ', 'Invalid Pair | Trader:', $pair->[0]->loginid, 'Copier:',           $pair->[1]->loginid);
    my $test_message = join(' ', $pair->[1]->loginid,      'following',         $pair->[0]->loginid, 'attempt. CopyTradingNotAllowed');
    subtest $test_name => sub {
        start_copy_trade_with_error_code($pair->[0], $pair->[1], 'CopyTradingNotAllowed', $test_message);
    };
}

####################################################################
# Test error checking
####################################################################

subtest 'Invalid trade type error' => sub {
    my $extra_args = {
        trade_types => 'CAL',
    };
    start_copy_trade_with_error_code($trader_CR, $copier_CR, 'InvalidTradeType', 'following attempt. InvalidTradeType', $extra_args);
};

subtest 'Invalid symbol error' => sub {
    my $extra_args = {
        trade_types => 'CALL',
        assets      => 'R666'
    };
    start_copy_trade_with_error_code($trader_CR, $copier_CR, 'InvalidSymbol', 'following attempt. InvalidSymbol', $extra_args);
};

subtest 'Invalid token error' => sub {
    start_copy_trade_with_error_code(undef, $copier_CR, 'InvalidToken', 'following attempt. InvalidToken');
};

subtest 'Copy trading not allowed error' => sub {
    start_copy_trade_with_error_code($copier_CR, $trader_CR, 'CopyTradingNotAllowed', 'following attempt. CopyTradingNotAllowed');
};

subtest 'Wrong currency error' => sub {
    top_up $EUR_copier, 'EUR', 1000;

    my $extra_args = {
        trade_types => 'CALL',
    };
    start_copy_trade_with_error_code($trader_CR, $EUR_copier, 'CopyTradingWrongCurrency', 'check currency', $extra_args);
};

subtest 'Copy trader without allow_copiers set' => sub {
    start_copy_trade_with_error_code($unset_trader, $copier_CR, 'CopyTradingNotAllowed', 'cannot follow trader without allow_copiers set');
};

####################################################################
# Copy Trading Statistics
####################################################################

subtest 'Copy trading statistics with no deposits for the current month' => sub {
    my $past       = Date::Utility->new()->_minus_months(1);
    my $past_month = $past->month();
    my $past_year  = $past->year();

    set_fixed_time($past->date, "%Y-%m-%d");

    set_allow_copiers($CR_client);

    top_up $CR_client, 'USD', 100;

    restore_time();

    buy_one_bet($CR_client);

    my $now   = Date::Utility->new();
    my $month = $now->month();
    my $year  = $now->year();

    my $statistics_response = copytrading_statistics($CR_client)->{monthly_profitable_trades};
    is $statistics_response->{"$past_year-$past_month"}, sprintf("%.4f", 0), "deposit ok for past month";
    isnt $statistics_response->{"$year-$month"}, undef, 'not undef for current month';
    isnt $statistics_response->{"$year-$month"}, sprintf("%.4f", 0), 'has only trades';

};

subtest 'Revoke trader token' => sub {

    subtest 'Normal copy trading' => sub {
        start_copy_trade($trader_CR, $copier_CR);
        top_up_account_and_check($trader_CR, 'USD', 1000);
        top_up_account_and_check($copier_CR, 'USD', 1000);
        buy_bet_and_check($trader_CR, $copier_CR, 1);
    };

    subtest 'Copy trades stop when trader token is revoked' => sub {
        my $old_token = $tokens{$trader_CR->loginid};
        BOM::Database::Model::OAuth->new->revoke_tokens_by_loginid($trader_CR->loginid);
        $tokens{$trader_CR->loginid} = BOM::Database::Model::OAuth->new->store_access_token_only(1, $trader_CR->loginid);
        buy_bet_and_check($trader_CR, $copier_CR, 0);

        my $res = $c->call_ok(
            'copy_stop',
            {
                args => {
                    copy_stop => $old_token,
                },
                token => $tokens{$copier_CR->loginid},
                %default_call_params
            })->has_no_error->result;
        ok($res && $res->{status}, "can stop following using the revoked token");

    };
};

####################################################################
# Helper methods
####################################################################

sub copy_trading_test_routine {

    my ($trader, $copier) = @_;
    my $fmbid;

    my $opening_balance = 15000;

    subtest 'Setup and fund trader' => sub {

        top_up_account_and_check($trader, 'USD', $opening_balance);
        top_up_account_and_check($copier, 'USD', 1);

        isnt($trader->account(), undef, 'got USD account');

        start_copy_trade($trader, $copier);
    };

    subtest 'Buy USD bet' => sub {
        $fmbid = buy_bet_and_check($trader, $copier, 0);
        # Expect the copier to fail on this call because it is not yet properly funded
    };

    subtest 'Fund copier' => sub {
        top_up_account_and_check($copier, 'USD', $opening_balance - 1);
    };

    subtest 'Buy 2nd USD bet' => sub {
        $fmbid = buy_bet_and_check($trader, $copier, 1);
    };

    sleep 1;

    subtest 'Sell 2nd USD bet' => sub {
        sell_bet_and_check($trader, $copier, $fmbid, 1);
    };

    subtest 'Get trader copiers' => sub {
        my $copiers = BOM::Database::DataMapper::Copier->new(
            broker_code => $trader->broker_code,
            operation   => 'replica',
            )->get_trade_copiers({
                trader_id => $trader->loginid,
            });
        is(scalar @$copiers, 1, 'get_trade_copiers');
        is($copiers->[0], $copier->loginid, 'trade copier is correct');
        note explain $copiers;
    };

    test_get_copiers_traders_tokens($trader, $copier->loginid);

    subtest 'Unfollow' => sub {
        stop_copy_trade($trader, $copier);

        $fmbid = buy_bet_and_check($trader, $copier, 0);
        # Copy should fail because we've unfollowed

        # Reset accounts back to zero
        top_up_account_and_check($trader, 'USD', $trader->account->balance * (-1));
        top_up_account_and_check($copier, 'USD', $copier->account->balance * (-1));
    };
}

sub buy_one_bet {
    my ($client, $args) = @_;

    my $buy_price    = delete $args->{buy_price}    // 20;
    my $payout_price = delete $args->{payout_price} // $buy_price * 10;
    my $limits       = delete $args->{limits};
    my $duration     = delete $args->{duration}     // '15s';

    my $loginid = $client->loginid;

    my $contract = produce_contract(Test::BOM::RPC::Contract::prepare_contract());

    my $params = {
        language            => 'EN',
        token               => $tokens{$loginid},
        source              => 1,
        contract_parameters => {
            "proposal"      => 1,
            "amount"        => "100",
            "basis"         => "payout",
            "contract_type" => "CALL",
            "currency"      => "USD",
            "duration"      => "15",
            "duration_unit" => "m",
            "symbol"        => "R_50",
        },
        args => {price => $contract->ask_price}};
    my $mock_validation = Test::MockModule->new('BOM::Transaction::Validation');
    $mock_validation->mock(validate_tnc => sub { note "mocked Transaction::Validation->validate_tnc returning nothing"; undef });

    my $result = $c->call_ok('buy', $params)->has_no_system_error->has_no_error->result;

    return @{$result}{qw| transaction_id contract_id balance_after buy_price |};
}

sub sell_one_bet {
    my ($client, $args) = @_;

    my $loginid = $client->loginid;

    my $params = {
        language => 'EN',
        token    => $tokens{$loginid},
        source   => 1,
        args     => {sell => $args->{id}}};

    my $result = $c->call_ok('sell', $params)->has_no_system_error->has_no_error->result;

    return @{$result}{qw| balance_after sold_for |};
}

sub set_allow_copiers {
    my $client = shift;

    my $email = $client->email;
    my $user  = BOM::User->create(
        email    => $email,
        password => '1234',
    );
    $user->add_client($client);

    my $args = {
        set_settings  => 1,
        allow_copiers => 1
    };
    if (not $client->is_virtual) {
        # This field is unrelated to the test, but required for this call to succeed on a real money account
        $args->{account_opening_reason} = "Speculative";
    }

    my $res = $c->call_ok(
        'set_settings',
        {
            args  => $args,
            token => $tokens{$client->loginid},
            %default_call_params
        })->result;

    is($res->{status}, 1, "allow_copiers set successfully");
}

sub start_copy_trade {
    my ($trader, $copier) = @_;

    my $res = $c->call_ok(
        'copy_start',
        {
            args => {
                copy_start => $tokens{$trader->loginid},
            },
            token => $tokens{$copier->loginid},
            %default_call_params
        })->has_no_error->result;
    ok($res && $res->{status}, "start following");
}

sub start_copy_trade_with_error_code {
    my ($trader, $copier, $error_code, $error_msg, $extra_args) = @_;
    $extra_args ||= {};

    my $trader_token = (defined $trader) ? $tokens{$trader->loginid} : "Invalid";
    my $copier_token = (defined $copier) ? $tokens{$copier->loginid} : "Invalid";

    my $res = $c->call_ok(
        'copy_start',
        {
            args => {
                copy_start => $trader_token,
                %$extra_args
            },
            token => $copier_token,
            %default_call_params
        })->has_error->error_code_is($error_code, $error_msg);
}

sub stop_copy_trade {
    my ($trader, $copier) = @_;

    my $res = $c->call_ok(
        'copy_stop',
        {
            args => {
                copy_stop => $tokens{$trader->loginid},
            },
            token => $tokens{$copier->loginid},
            %default_call_params
        })->has_no_error->result;
    ok($res && $res->{status}, "stop following");
}

sub buy_bet_and_check {
    my ($trader, $copier, $copy_success_expected) = @_;

    my $trader_balance = $trader->account->balance + 0;
    my $copier_balance = $copier->account->balance + 0;

    my ($txnid, $fmbid, $balance_after, $buy_price) = buy_one_bet($trader);

    my $expected_copier_balance = $copier_balance - ($copy_success_expected ? $buy_price : 0);
    my $expected_trader_balance = $trader_balance - $buy_price;

    is(int $balance_after,            int $expected_trader_balance, 'correct balance_after');
    is(int $copier->account->balance, int $expected_copier_balance, "correct copier balance");
    is(int $trader->account->balance, int $expected_trader_balance, "correct trader balance");

    return $fmbid;
}

sub sell_bet_and_check {
    my ($trader, $copier, $fmbid, $copy_success_expected) = @_;

    my $copier_balance = $copier->account->balance + 0;
    my $trader_balance = $trader->account->balance + 0;

    my ($balance_after, $sell_price) = sell_one_bet(
        $trader,
        +{
            id => $fmbid,
        });

    my $expected_copier_balance = $copier_balance + ($copy_success_expected ? $sell_price : 0);
    my $expected_trader_balance = $trader_balance + $sell_price;

    is(int $balance_after,            int $expected_trader_balance, 'correct balance_after');
    is(int $copier->account->balance, int $expected_copier_balance, "correct copier balance");
    is(int $trader->account->balance, int $expected_trader_balance, "correct trader balance");
}

sub top_up_account_and_check {
    my ($client, $currency, $amount) = @_;

    my $previous_balance = ref $client->account ? $client->account->balance : 0;
    my $expected_balance = $previous_balance + $amount;

    top_up $client, $currency, $amount;

    my $new_balance = ref $client->account ? $client->account->balance : 0;
    is(int($new_balance), int($expected_balance), $currency . ' balance should be ' . $expected_balance . ' got: ' . $new_balance);
}

sub copytrading_statistics {
    my ($trader) = @_;

    my $res = $c->call_ok(
        'copytrading_statistics',
        {
            args => {
                copytrading_statistics => 1,
                trader_id              => $trader->loginid,
            },
            token => $tokens{$trader->loginid},
            %default_call_params
        })->has_no_error->result;
    return $res;
}

sub test_get_copiers_traders_tokens {
    my $client = shift;
    my $loginid = shift;

    my $params = {
        token => $tokens{$client->loginid},
        %default_call_params
    };

    my $res = $c->call_ok('get_copiers_traders_tokens', $params)->result;
    is $res->{copiers}[0][0], $loginid, 'get_copiers_traders_tokens';
}

done_testing;
