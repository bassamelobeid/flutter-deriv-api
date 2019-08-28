use strict;
use warnings;

use utf8;
use Test::Most;
use Test::Mojo;
use Try::Tiny;
use Test::MockTime qw(set_relative_time);

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestRedis qw(initialize_realtime_ticks_db);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Database::Model::OAuth;
use BOM::Test::Localize qw(is_localized);

use BOM::Test::RPC::Client;

initialize_realtime_ticks_db();

my $email  = 'test@binary.com';
my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'VRTC',
    email       => $email,
});
$client->deposit_virtual_funds;

my $loginid = $client->loginid;
my ($token) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $loginid);
my $app = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
    'currency',
    {
        symbol => 'USD',
        date   => Date::Utility->new
    });

subtest 'audit_details tick names translations' => sub {
    my $now  = Date::Utility->new();
    my $args = {
        date_start          => $now,
        date_pricing        => $now,
        token               => $token,
        source              => 1,
        contract_parameters => {
            proposal      => 1,
            amount        => 100,
            basis         => "payout",
            contract_type => "TICKHIGH",
            currency      => "USD",
            duration      => 5,
            duration_unit => "t",
            symbol        => "R_50",
            selected_tick => 5,
        },
        args => {
            price => 100,
        }};

    my $contract_high = $app->call_ok('buy', $args)->has_no_system_error->has_no_error->result->{contract_id};
    $args->{contract_parameters}{contract_type} = "TICKLOW";
    $args->{contract_parameters}{selected_tick} = 1;
    my $contract_low = $app->call_ok('buy', $args)->has_no_system_error->has_no_error->result->{contract_id};

    sleep(1);
    for my $i (0 .. 10) {
        BOM::Test::Data::Utility::FeedTestDatabase::create_tick({
            underlying => 'R_50',
            quote      => 100 + $i * 0.1,
            epoch      => $now->epoch + $i,
        });
    }

    set_relative_time(10);

    check_results(
        $contract_high,
        '<LOC>Win payout if tick 5 of <LOC>Volatility 50 Index</LOC> is the highest among all <LOC>5</LOC> ticks.</LOC>',
        '<LOC>Start Time</LOC>',
        '<LOC>Entry Spot</LOC>',
        '<LOC><LOC><LOC>End Time</LOC> and <LOC>Exit Spot</LOC></LOC> and <LOC>Highest Spot</LOC></LOC>'
    );
    check_results(
        $contract_low,
        '<LOC>Win payout if tick 1 of <LOC>Volatility 50 Index</LOC> is the lowest among all <LOC>5</LOC> ticks.</LOC>',
        '<LOC>Start Time</LOC>',
        '<LOC><LOC>Entry Spot</LOC> and <LOC>Lowest Spot</LOC></LOC>',
        '<LOC><LOC>End Time</LOC> and <LOC>Exit Spot</LOC></LOC>'
    );
};

sub check_results {
    my $contract_id = shift;
    my $longcode    = shift;
    my $params      = {
        language    => 'EN',
        token       => $token,
        contract_id => $contract_id,
    };

    my $result = $app->call_ok('proposal_open_contract', $params)->has_no_system_error->has_no_error->result;
    ok(is_localized($result->{$contract_id}->{longcode}), 'contract longcode is properly localized');
    is($result->{$contract_id}->{longcode}, $longcode, 'Longcode message is correct');
    ok($result->{$contract_id}->{is_expired},    'Transaction is expired');
    ok($result->{$contract_id}->{audit_details}, 'Audit details are available');
    for (@{$result->{$contract_id}->{audit_details}->{contract_start}}) {
        my $tick = $_;
        if ($tick->{name}) {
            my $name = shift;
            is($tick->{name}, $name, 'Correct tick name');
            ok(is_localized($tick->{name}), 'Start tick name is correctly localized');
        }
    }
    for (@{$result->{$contract_id}->{audit_details}->{contract_end}}) {
        my $tick = $_;
        if ($tick->{name}) {
            my $name = shift;
            is($tick->{name}, $name, 'Correct tick name');
            ok(is_localized($tick->{name}), 'End tick name is correctly localized') if $tick->{name};
        }
    }
}

done_testing();
