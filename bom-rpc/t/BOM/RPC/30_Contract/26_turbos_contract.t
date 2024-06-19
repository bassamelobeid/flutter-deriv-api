#!perl
use strict;
use warnings;
use BOM::Test::RPC::QueueClient;
use Test::Most;
use Test::Mojo;
use Test::MockModule;

use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Pricing::v3::Contract;
use BOM::Platform::Context                       qw(request);
use BOM::Product::ContractFactory                qw(produce_contract);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);

my $now             = Date::Utility->new;
my $landing_company = 'virtual';
my $residence       = "aq";
my $email           = 'virtual-aq@binary.com';

my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    residence   => $residence,
    email       => $email,
});

my $loginid = $client->loginid;
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);

BOM::Test::Data::Utility::FeedTestDatabase::flush_and_create_ticks([100, $now->epoch, 'R_100'], [100, $now->epoch + 1, 'R_100']);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol        => 'USD',
        recorded_date => $now
    });

my $c = BOM::Test::RPC::QueueClient->new();
request(BOM::Platform::Context::Request->new(params => {}));

subtest 'turbos - send_ask' => sub {
    my $args = {
        "proposal"      => 1,
        "amount"        => 100,
        "barrier"       => "-13.11",
        "basis"         => "payout",
        "contract_type" => "TURBOSLONG",
        "currency"      => "USD",
        "duration"      => 60,
        "duration_unit" => "s",
        "symbol"        => "R_100"
    };
    my $params = {
        client_ip => '127.0.0.1',
        token     => $token,
        args      => $args,
    };

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')->error_message_is('Basis must be stake for this contract.');

    $args->{basis} = 'stake';
    delete $args->{duration};

    $c->call_ok('send_ask', $params)->has_error->error_code_is('ContractCreationFailure')
        ->error_message_is('Please specify either duration or date_expiry.');

    $args->{duration} = 60;

    my $expected = {
        ask_price       => "100.00",
        auth_time       => ignore(),
        barrier_choices => ignore(),
        channel         =>
            "PRICER_ARGS::[\"amount\",\"100\",\"barrier\",\"-13.11\",\"basis\",\"stake\",\"contract_type\",\"TURBOSLONG\",\"country_code\",null,\"currency\",\"USD\",\"duration\",\"60\",\"duration_unit\",\"s\",\"landing_company\",\"virtual\",\"price_daemon_cmd\",\"price\",\"proposal\",\"1\",\"skips_price_validation\",\"1\",\"symbol\",\"R_100\"]",
        contract_details    => {barrier => 86.89},
        contract_parameters => {
            amount                => 100,
            amount_type           => "stake",
            app_markup_percentage => 0,
            barrier               => -13.11,
            base_commission       => 0,
            bet_type              => "TURBOSLONG",
            currency              => "USD",
            date_start            => 0,
            deep_otm_threshold    => 0.025,
            duration              => "60s",
            landing_company       => "virtual",
            min_commission_amount => 0.02,
            proposal              => 1,
            token_details         => {
                epoch          => ignore(),
                loginid        => "VRTC1002",
                scopes         => ["read", "admin", "trade", "payments"],
                ua_fingerprint => undef,
            },
            underlying => "R_100",
        },
        date_expiry                 => ignore(),
        date_start                  => ignore(),
        display_number_of_contracts => "7.614600",
        display_value               => "100.00",
        longcode                    => ignore(),
        max_stake                   => ignore(),
        min_stake                   => ignore(),
        payout                      => 0,
        rpc_time                    => ignore(),
        skip_streaming              => 0,
        spot                        => "100.00",
        spot_time                   => ignore(),
        stash                       => {
            app_markup_percentage      => 0,
            market                     => "synthetic_index",
            source_bypass_verification => 0,
            source_type                => "official",
            valid_source               => 1,
        },
        subchannel           => "v1,USD,100,stake,0,0.025,0,0.02,,,,,EN",
        subscription_channel =>
            "PRICER_ARGS::[\"amount\",\"100\",\"barrier\",\"-13.11\",\"basis\",\"stake\",\"contract_type\",\"TURBOSLONG\",\"country_code\",null,\"currency\",\"USD\",\"duration\",\"60\",\"duration_unit\",\"s\",\"landing_company\",\"virtual\",\"price_daemon_cmd\",\"price\",\"proposal\",\"1\",\"skips_price_validation\",\"1\",\"symbol\",\"R_100\"]::v1,USD,100,stake,0,0.025,0,0.02,,,,,EN",
    };

    my $redis_mock = Test::MockModule->new('RedisDB');
    $redis_mock->mock(
        'hget',
        sub {
            my ($self, @args) = @_;
            return '{"tick_epoch":"123123123"}';
        });

    my $res = $c->call_ok('send_ask', $params)->has_no_error->result;
    cmp_deeply($res, $expected, 'send_ask output as expected');

};

subtest 'turbos - get_bid' => sub {
    my $contract = produce_contract({
        bet_type     => 'TurbosLong',
        underlying   => 'R_100',
        date_start   => $now,
        date_pricing => $now,
        duration     => '10h',
        currency     => 'USD',
        amount_type  => 'stake',
        amount       => 10,
        barrier      => '+0.40',
    });

    my $params = {
        short_code      => $contract->shortcode,
        contract_id     => $contract->id,
        currency        => 'USD',
        is_sold         => 0,
        country_code    => 'cr',
        landing_company => 'virtual',
    };

    my $expected = {
        audit_details => {
            contract_end => [{
                    epoch              => ignore(),
                    flag               => "highlight_tick",
                    name               => "Exit Spot",
                    tick               => 100,
                    tick_display_value => "100.00",
                },
            ],
            contract_start => [{
                    epoch              => ignore(),
                    flag               => "highlight_tick",
                    name               => "Start Time and Entry Spot",
                    tick               => 100,
                    tick_display_value => "100.00",
                },
                {
                    epoch              => ignore(),
                    tick               => 100,
                    tick_display_value => "100.00"
                },
            ],
        },
        barrier                     => "100.40",
        barrier_count               => 1,
        bid_price                   => "0.00",
        contract_id                 => 520,
        contract_type               => "TURBOSLONG",
        currency                    => "USD",
        current_spot                => 100,
        current_spot_display_value  => "100.00",
        current_spot_time           => ignore(),
        date_expiry                 => ignore(),
        date_settlement             => ignore(),
        date_start                  => ignore(),
        display_name                => "Volatility 100 Index",
        display_number_of_contracts => "0.100000",
        entry_spot                  => 100,
        entry_spot_display_value    => "100.00",
        entry_tick                  => 100,
        entry_tick_display_value    => "100.00",
        entry_tick_time             => ignore(),
        exit_tick                   => 100,
        exit_tick_display_value     => "100.00",
        exit_tick_time              => ignore(),
        expiry_time                 => ignore(),
        is_expired                  => 1,
        is_forward_starting         => 0,
        is_intraday                 => 1,
        is_path_dependent           => 1,
        is_settleable               => 1,
        is_sold                     => 0,
        is_valid_to_cancel          => 0,
        is_valid_to_sell            => 1,
        longcode                    => ignore(),
        shortcode                   => ignore(),
        stash                       => {
            app_markup_percentage      => 0,
            source_bypass_verification => 0,
            source_type                => "official",
            valid_source               => 1,
        },
        status     => "open",
        underlying => "R_100",
    };
    my $res = $c->call_ok('get_bid', $params)->has_no_system_error->has_no_error->result;
    cmp_deeply($res, $expected, 'get_bid as expected');
};

done_testing();
