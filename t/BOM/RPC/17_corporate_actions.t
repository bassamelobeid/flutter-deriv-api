use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Test::MockModule;
use BOM::RPC::v3::Contract;
use BOM::Platform::Context qw (request);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::System::RedisReplicated;
use BOM::Product::ContractFactory qw( produce_contract );
use Data::Dumper;

use Quant::Framework::CorporateAction;
use Quant::Framework::Utils::Test;

initialize_realtime_ticks_db();

my $now    = Date::Utility->new('2005-09-21 06:46:00');
my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my $token = BOM::Platform::SessionCookie->new(
    loginid => $client->loginid,
    email   => $email
)->token;

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD AUD CAD-AUD);
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'randomindex',
    {
        symbol => 'R_50',
        date   => Date::Utility->new
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $_,
        recorded_date => $now
    }) for qw (frxAUDCAD frxUSDCAD frxAUDUSD);

#Create_doc for symbol FPFP
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'EUR',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'index',
    {
        symbol => 'FPFP',
        date   => Date::Utility->new,
    });
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => 'FPFP',
        recorded_date => Date::Utility->new,
    });

my $date       = Date::Utility->new('2013-03-27');
my $opening    = BOM::Market::Underlying->new('FPFP')->exchange->opening_on($date);
my $underlying = BOM::Market::Underlying->new('FPFP');
my $starting   = $underlying->exchange->opening_on(Date::Utility->new('2013-03-27'))->plus_time_interval('50m');
my $entry_tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch,
    quote      => 100
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 30,
    quote      => 111
});
BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
    underlying => 'FPFP',
    epoch      => $starting->epoch + 90,
    quote      => 80
});

###

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
request(BOM::Platform::Context::Request->new(params => {l => 'ZH_CN'}));

subtest 'get_corporate_actions' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 899,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 850,
        underlying => 'R_50',
    });
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract = create_contract(
        client        => $client,
        spread        => 0,
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901
    );
    my $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };
    my $result =
        $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        '在合约期限内出现市场数据中断。对于真实资金账户，我们将尽力修正并恰当地结算合约，不然合约将取消及退款。对于虚拟资金交易，我们将取消交易，并退款。'
        );
    $params = {language => 'ZH_CN'};

    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is('对不起，在处理您的请求时出错。');

    $contract = create_contract(
        client => $client,
        spread => 1
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    my @expected_keys = (
        qw(ask_price
            bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
            is_forward_starting
            is_path_dependent
            is_intraday
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            payout
            contract_type
            display_name
            ));
    is_deeply([sort keys %{$result}], [sort @expected_keys]);

    $contract = create_contract(
        client => $client,
        spread => 0
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    push @expected_keys, qw(
        barrier
        exit_tick_time
        exit_tick
        entry_tick
        entry_tick_time
        current_spot
        entry_spot
    );
    is_deeply([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');

};

subtest 'get_bid' => sub {
    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 899,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 850,
        underlying => 'R_50',
    });
    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });

    my $contract = create_contract(
        client        => $client,
        spread        => 0,
        current_tick  => $tick,
        date_start    => $now->epoch - 900,
        date_expiry   => $now->epoch - 500,
        purchase_date => $now->epoch - 901
    );
    my $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };
    my $result =
        $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is(
        '在合约期限内出现市场数据中断。对于真实资金账户，我们将尽力修正并恰当地结算合约，不然合约将取消及退款。对于虚拟资金交易，我们将取消交易，并退款。'
        );
    $params = {language => 'ZH_CN'};

    $c->call_ok('get_bid', $params)->has_error->error_code_is('GetProposalFailure')
        ->error_message_is('对不起，在处理您的请求时出错。');

    $contract = create_contract(
        client => $client,
        spread => 1
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    my @expected_keys = (
        qw(ask_price
            bid_price
            current_spot_time
            contract_id
            underlying
            is_expired
            is_valid_to_sell
            is_forward_starting
            is_path_dependent
            is_intraday
            date_start
            date_expiry
            date_settlement
            currency
            longcode
            shortcode
            payout
            contract_type
            display_name
            ));
    is_deeply([sort keys %{$result}], [sort @expected_keys]);

    $contract = create_contract(
        client => $client,
        spread => 0
    );

    $params = {
        language    => 'ZH_CN',
        short_code  => $contract->shortcode,
        contract_id => $contract->id,
        currency    => $client->currency,
        is_sold     => 0,
    };

    $result = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;

    push @expected_keys, qw(
        barrier
        exit_tick_time
        exit_tick
        entry_tick
        entry_tick_time
        current_spot
        entry_spot
    );
    is_deeply([sort keys %{$result}], [sort @expected_keys], 'keys of result is correct');

};

done_testing();

sub create_contract {
    my %args = @_;

    my $client = $args{client};
    #postpone 10 minutes to avoid conflicts
    $now = $now->plus_time_interval('10m');

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 99,
        underlying => 'R_50',
    });

    BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch - 52,
        underlying => 'R_50',
    });

    my $tick = BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
        epoch      => $now->epoch,
        underlying => 'R_50',
    });
    my $symbol        = $args{underlying} ? $args{underlying} : 'R_50';
    my $date_start    = $now->epoch - 100;
    my $date_expiry   = $now->epoch - 50;
    my $underlying    = BOM::Market::Underlying->new($symbol);
    my $purchase_date = $now->epoch - 101;
    my $contract_data = {
        underlying   => $underlying,
        bet_type     => 'FLASHU',
        currency     => 'USD',
        current_tick => $args{current_tick} ? $args{current_tick} : $tick,
        stake        => 100,
        date_start   => $args{date_start} ? $args{date_start} : $date_start,
        date_expiry  => $args{date_expiry} ? $args{date_expiry} : $date_expiry,
        barrier      => 'S0P',
    };

    if ($args{spread}) {
        delete $contract_data->{date_expiry};
        delete $contract_data->{barrier};
        $contract_data->{bet_type}         = 'SPREADU';
        $contract_data->{amount_per_point} = 1;
        $contract_data->{stop_type}        = 'point';
        $contract_data->{stop_profit}      = 10;
        $contract_data->{stop_loss}        = 10;
    }
    my $contract = produce_contract($contract_data);

    my $txn = BOM::Product::Transaction->new({
        client        => $client,
        contract      => $contract,
        price         => 100,
        payout        => $contract->payout,
        amount_type   => 'stake',
        purchase_date => $args{purchase_date} ? $args{purchase_date} : $purchase_date,
    });

    my $error = $txn->buy(skip_validation => 1);
    ok(!$error, 'should no error to buy the contract');

    return $contract;
}
