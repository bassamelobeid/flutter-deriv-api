use strict;
use warnings;
use Date::Utility;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use Test::Refcount;
use Scalar::Util qw(weaken);

use Test::More;
use Test::Deep;
use Date::Utility;

use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use BOM::Product::Contract::PredefinedParameters qw(generate_trading_periods);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use Binary::WebSocketAPI::v3::Instance::Redis qw| redis_pricer |;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Config::RedisReplicated;
use BOM::Config::Chronicle;
use BOM::MarketData qw(create_underlying);
use BOM::Product::ContractFactory qw(produce_contract);

use Sereal::Encoder;
use Quant::Framework;
use Role::Tiny;

my $encoder = Sereal::Encoder->new({
    canonical => 1,
});

my $redis = BOM::Config::RedisReplicated::redis_write();
my @tick_data;
my $start_time    = time;
my $previous_tick = 100;
my $ticks_count   = 80;

for (my $epoch = $start_time - $ticks_count * 15; $epoch <= $start_time; $epoch += 15) {
    $previous_tick += (-1**($epoch % 2) * ($start_time - $epoch)) / ($ticks_count * 15 * 100);
    push @tick_data,
        +{
        symbol         => 'frxUSDJPY',
        epoch          => $epoch,
        decimate_epoch => $epoch,
        quote          => $previous_tick
        };
}

$redis->zadd('DECIMATE_frxUSDJPY_15s_DEC', $_->{epoch}, $encoder->encode($_)) for @tick_data;

my $response;

my $currency = "USD";
my $lc       = 'svg';
my $pt       = 'multi_barrier';
my $symbol   = "frxUSDJPY";

my $now = Date::Utility->new;

my $contract_type_pairs = {
    "PUT"        => "CALLE",
    "ONETOUCH"   => "NOTOUCH",
    "EXPIRYMISS" => "EXPIRYRANGEE",
    "RANGE"      => "UPORDOWN",
};

my $trading_frames = {};
my $tp = BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_parameters_for($symbol, Date::Utility->new);
initialize_realtime_ticks_db();

BOM::Test::Data::Utility::UnitTestMarketData::create_doc('currency', {symbol => $_}) for qw(USD JPY);

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
BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'volsurface_delta',
    {
        symbol        => $symbol,
        recorded_date => $now
    });

my $t = build_wsapi_test();

my $contracts_for = $t->await::contracts_for({
    "contracts_for"   => $symbol,
    "currency"        => $currency,
    "landing_company" => $lc,
    "product_type"    => $pt,
});

my @contract_types = (keys %$contract_type_pairs, values %$contract_type_pairs);
my $proposal_array_variants = {};
for my $i (0 .. $#{$contracts_for->{contracts_for}{available}}) {
    my $tf = $contracts_for->{contracts_for}{available}[$i]{trading_period}{duration};
    $trading_frames->{$tf} = 1;
    my $ct = $contracts_for->{contracts_for}{available}[$i]{contract_type};
    next unless exists $contract_type_pairs->{$ct};
    my $key = $ct . '_' . $contract_type_pairs->{$ct} . '_' . $tf;
    next if exists $proposal_array_variants->{$key};
    $proposal_array_variants->{$key} = {
        available_barriers   => $contracts_for->{contracts_for}{available}[$i]{available_barriers},
        barriers             => $contracts_for->{contracts_for}{available}[$i]{barriers},
        date_expiry          => $contracts_for->{contracts_for}{available}[$i]{trading_period}{date_expiry}{epoch},
        trading_period_start => $contracts_for->{contracts_for}{available}[$i]{trading_period}{date_start}{epoch},
    };
}

my $proposal_array_req_tpl = {
    'symbol'               => $symbol,
    'req_id'               => '1',
    'barriers'             => undef,
    'date_expiry'          => undef,
    'currency'             => 'JPY',
    'amount'               => '100',
    'trading_period_start' => undef,
    'basis'                => 'payout',
    'proposal_array'       => '1',
    'contract_type'        => undef,
    'passthrough'          => {}};

my $trading_calendar = Quant::Framework->new->trading_calendar(BOM::Config::Chronicle::get_chronicle_reader());
my $market_closed    = !$trading_calendar->is_open_at(create_underlying($symbol)->exchange, Date::Utility->new);
my $no_offerings     = ($contracts_for->{error}{code} // '') eq 'InvalidSymbol';
ok(Date::Utility->new->time_hhmmss ge '18:15:00' || Date::Utility->new->time_hhmmss lt '00:15:00' || $market_closed,
    "$symbol $pt is unavailable at this time")
    if $no_offerings;
my $skip = $market_closed || $no_offerings;

SKIP: {
    skip "Forex test does not work on the weekends or $symbol $pt contracts unavailability.", 1 if $skip;
    subtest 'allcombinations' => sub {
        for my $key (keys %$proposal_array_variants) {
            my ($ct1, $ct2) = split '_', $key;
            my $data      = $proposal_array_variants->{$key};
            my $fbarriers = [];
            if ($data->{barriers} == 2) {
                $fbarriers = [map { {barrier2 => $_->[0], barrier => $_->[1]} } @{$data->{available_barriers}}];
            } else {
                $fbarriers = [map { {barrier => $_} } @{$data->{available_barriers}}];
            }
            $proposal_array_req_tpl->{barriers}             = $fbarriers;
            $proposal_array_req_tpl->{date_expiry}          = $data->{date_expiry};
            $proposal_array_req_tpl->{trading_period_start} = $data->{trading_period_start};
            $proposal_array_req_tpl->{contract_type}        = [$ct1, $ct2];
            my $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);
        }
    };
}

# Regenerate trading periods here to try avoid below bail out.
BOM::Test::Data::Utility::FeedTestDatabase->instance->truncate_tables();
BOM::Test::Data::Utility::UnitTestMarketData::create_predefined_parameters_for($symbol, Date::Utility->new);

$contracts_for = $t->await::contracts_for({
    "contracts_for"   => $symbol,
    "currency"        => $currency,
    "landing_company" => $lc,
    "product_type"    => $pt,
});

my $put_array = [grep { $_->{contract_type} eq 'PUT' and $_->{trading_period}{duration} eq '2h' } @{$contracts_for->{contracts_for}{available}}];
unless (scalar @$put_array) {
    # fallback if there is no 2h contracts
    $put_array = [grep { $_->{contract_type} eq 'PUT' and $_->{trading_period}{duration} eq '0d' } @{$contracts_for->{contracts_for}{available}}];
}
# Try avoid bail out below by using the latest window available for 2h contract duration.
my $put = $put_array->[scalar(@{$put_array}) - 1];

my $barriers = $put->{available_barriers};
my $fixed_bars = [map { {barrier => $_} } @$barriers];

SKIP: {
    skip "Forex test does not work on the weekends or $symbol $pt contract unavailability.", 1 if $skip;
    if ($put->{trading_period}{date_expiry}{epoch} - Date::Utility->new->epoch <= 900) {
        $response = $t->await::proposal_array($proposal_array_req_tpl);
        is $response->{proposal_array}{proposals}{CALLE}[0]{error}{message}, 'Trading is not offered for this duration.',
            "ContractBuyValidationError : Trading is not offered for this duration.";
    } else {
        subtest "one barrier, one contract_type" => sub {
            $proposal_array_req_tpl->{barriers}             = $fixed_bars;
            $proposal_array_req_tpl->{date_expiry}          = $put->{trading_period}{date_expiry}{epoch};
            $proposal_array_req_tpl->{trading_period_start} = $put->{trading_period}{date_start}{epoch};
            $proposal_array_req_tpl->{contract_type}        = ['CALLE', 'PUT'];

            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            $proposal_array_req_tpl->{barriers} = [{barrier => $put->{available_barriers}[0]}];

            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            $proposal_array_req_tpl->{barriers} = $fixed_bars, $proposal_array_req_tpl->{contract_type} = ['CALLE'];

            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            $proposal_array_req_tpl->{barriers} = [{barrier => $put->{available_barriers}[0]}];

            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);
        };

        subtest "various results" => sub {
            # We add 120 here because we want to increase the duration from 1 to 3 minutes.
            $proposal_array_req_tpl->{date_expiry}          = $put->{trading_period}{date_expiry}{epoch} + 120;
            $proposal_array_req_tpl->{trading_period_start} = $put->{trading_period}{date_start}{epoch};

            # And this line set amount to higher value to fix the minimum stake validation failure that seems to happen based
            # on the timing this test runs.
            $proposal_array_req_tpl->{amount}        = 1000;
            $proposal_array_req_tpl->{barriers}      = [{barrier => 111}];
            $proposal_array_req_tpl->{contract_type} = ['CALLE'];
            $proposal_array_req_tpl->{product_type}  = 'multi_barrier';
            $proposal_array_req_tpl->{currency}      = 'USD';
            $response                                = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            is $response->{proposal_array}{proposals}{CALLE}[0]{error}{message}, 'Invalid expiry time.',
                "ContractBuyValidationError : Invalid expiry time";

            $proposal_array_req_tpl->{barriers} = [{barrier => 111}];
            # Here we reset the amount back to 100 to ensure we get the minimum stake error for the next test.
            $proposal_array_req_tpl->{amount} = 100;
            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);
            ok $response->{proposal_array}{proposals}{CALLE}[0]{error},
                "ContractBuyValidationError : Minimum stake of 35 and maximum payout of 100000.";

            $proposal_array_req_tpl->{barriers} = [{barrier => 109}];
            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);
            ok $response->{proposal_array}{proposals}{CALLE}[0]{error}, "ContractBuyValidationError : This contract offers no return.";
        };

        subtest 'subscriptions' => sub {
            $t->await::forget_all({forget_all => "proposal_array"});
            $t->await::forget_all({forget_all => "proposal"});
            $t->await::forget_all({forget_all => "proposal_open_contract"});

            $proposal_array_req_tpl->{date_expiry}          = $put->{trading_period}{date_expiry}{epoch};
            $proposal_array_req_tpl->{trading_period_start} = $put->{trading_period}{date_start}{epoch};

            $proposal_array_req_tpl->{barriers} = [{barrier => 97}];
            $proposal_array_req_tpl->{contract_type} = ['CALLE'];

            $proposal_array_req_tpl->{subscribe} = 1;

            $response = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            my $uuid = $response->{proposal_array}->{id};
            ok $uuid, "There is an id";
            is $response->{subscription}->{id}, $uuid, "And it is the same as the subscription id";

            my $failure = $t->await::proposal_array($proposal_array_req_tpl);
            is $failure->{error}->{code}, 'AlreadySubscribed', 'Error when subscribed again';

            my ($c) = values %{$t->app->active_connections};

            my $uuid_channel_stash = $c->stash('uuid_channel');

            my @subscriptions = values %$uuid_channel_stash;
            is(scalar @subscriptions, 2, "Subscription created");
            @subscriptions = grep { $_->status } @subscriptions;
            is(scalar @subscriptions, 1, "1 subscripion is really subscribed");
            my $subscription = pop @subscriptions;
            weaken($subscription);
            ok(Role::Tiny::does_role($subscription, 'Binary::WebSocketAPI::v3::Subscription::Pricer'), 'is a pricer subscription');
            is_oneref($subscription, '1 refcount');

            ok(redis_pricer->get($subscription->channel), "check redis subscription");
            explain "uuid is " . $subscription->uuid;
            explain "subscribed ? " . $subscription->status;
            $response = $t->await::forget_all({forget_all => "proposal_array"});
            ok(!$subscription, 'subscription is destroyed');
            is @{$response->{forget_all}}, 1, 'Correct number of subscriptions forgotten';
            is $response->{forget_all}->[0], $uuid, 'Correct subscription id returned';
        };

        subtest 'using durations' => sub {
            delete $proposal_array_req_tpl->{date_expiry};

            $proposal_array_req_tpl->{duration}      = 1;
            $proposal_array_req_tpl->{duration_unit} = 'd';
            $response                                = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            $proposal_array_req_tpl->{duration} = 100000000;
            $response = $t->await::proposal_array($proposal_array_req_tpl);
            is $response->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with huge duration';

            $proposal_array_req_tpl->{duration} = -10;
            $response = $t->await::proposal_array($proposal_array_req_tpl);
            is $response->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with huge duration';
        };

        subtest 'invalid barrier' => sub {
            delete $proposal_array_req_tpl->{date_expiry};

            $proposal_array_req_tpl->{duration}      = 1;
            $proposal_array_req_tpl->{duration_unit} = 'd';
            $response                                = $t->await::proposal_array($proposal_array_req_tpl);
            test_schema('proposal_array', $response);

            $proposal_array_req_tpl->{barrier} = "1.0000000000000000000000000000000000000000";
            $response = $t->await::proposal_array($proposal_array_req_tpl);
            is $response->{error}->{code}, 'InputValidationFailed', 'Schema validation fails with invalid barrier';
            is $response->{error}->{message}, 'Input validation failed: barrier', 'Schema validation fails with correct error message';
        };
    }
}

#use Data::Dumper;
#print Dumper $proposal_array_req_tpl;
$t->finish_ok;

done_testing();

