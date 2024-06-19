use Test::Most;
use Test::MockTime::HiRes qw(set_absolute_time);
use Date::Utility;
use Test::MockModule;
use Test::MockObject;

use BOM::Pricing::v3::MarketData;

my $mock_lc = Test::MockModule->new('LandingCompany::Offerings');
$mock_lc->mock(is_asian_hours => sub { return 0 });

my $mock_chronicle = Test::MockModule->new('BOM::Config::Chronicle');
$mock_chronicle->mock('get_chronicle_reader' => sub { return bless {} });

my $mock_config = Test::MockModule->new('BOM::Config::Runtime');
$mock_config->mock(
    get_offerings_config => sub {
        return {
            action                     => "buy",
            loaded_revision            => 1614927607.64481,
            suspend_contract_types     => [],
            suspend_markets            => [],
            suspend_trading            => 0,
            suspend_underlying_symbols => ["frxAUDPLN", "JCI"],
        };
    });

my $mock_self = Test::MockModule->new('BOM::Pricing::v3::MarketData');
$mock_self->mock(
    _get_cache => sub { },
    _set_cache => sub { },
);

my $client_obj = Test::MockObject->new();
$client_obj->mock('landing_company', sub { return bless {short => 'malta'}, 'LandingCompany' });
$client_obj->mock('residence',       sub { return 'de' });
my $mock_client = Test::MockModule->new('BOM::User::Client');
$mock_client->mock('new', sub { return $client_obj });

sub _test_asset_index {
    my ($params, $first_entry) = @_;
    my $result = BOM::Pricing::v3::MarketData::asset_index($params);

    # dd($result->[0][2]);
    is($result->[0][0], $first_entry->[0], "first asset code is " . ($first_entry->[0] // 'undefined'));
    is($result->[0][1], $first_entry->[1], "first asset name is " . ($first_entry->[1] // 'undefined'));
    cmp_deeply($result->[0][2] // [], bag(@{$first_entry->[2]}), 'contract types list match');
    my $contract_count = scalar @{$first_entry->[2]};
    is(scalar @{$result->[0][2]}, $contract_count, "$contract_count contract types");
}

subtest "asset_index" => sub {
    my $first_entry_malta = [];

    my $first_entry_cr = [
        "frxAUDJPY",
        "AUD/JPY",
        [
            ["callput",       "Higher/Lower",               "1d",  "365d"],
            ["callput",       "Rise/Fall",                  "15m", "365d"],
            ["touchnotouch",  "Touch/No Touch",             "1d",  "365d"],
            ["endsinout",     "Ends Between/Ends Outside",  "1d",  "365d"],
            ["staysinout",    "Stays Between/Goes Outside", "1d",  "365d"],
            ["callputequal",  "Rise/Fall Equal",            "15m", "365d"],
            ["callputspread", "Call Spread/Put Spread",     "15m", "2h"],
            ["multiplier",    "Multiply Up/Multiply Down",  "",    ""],       # logged out will be default to virtual
        ]];

    note "asset_index malta landing_company";
    _test_asset_index({
            language => 'en',
            args     => {landing_company => 'malta'}
        },
        $first_entry_malta,
    );

    note "asset_index malta client token";
    _test_asset_index({
            language      => 'en',
            token_details => {loginid => 'dummy_malta'}
        },
        $first_entry_malta,
    );

    note "asset_index default";
    _test_asset_index({}, $first_entry_cr);
};

subtest "trading_durations" => sub {
    my $trade_durations_cr = {
        market    => {name => 'forex'},
        submarket => {name => 'major_pairs'},
        data      => [{
                trade_durations => [{
                        durations => [{
                                display_name => "Minutes",
                                max          => 1440,
                                min          => 15,
                                name         => "m"
                            },
                            {
                                display_name => "Hours",
                                max          => 24,
                                min          => 1,
                                name         => "h"
                            },
                            {
                                display_name => "Days",
                                max          => 365,
                                min          => 1,
                                name         => "days"
                            },
                        ],
                        trade_type => {
                            display_name => "Rise/Fall",
                            name         => "rise_fall"
                        },
                    }]}]};

    my $trade_durations_malta = {};

    note 'trading_durations for malta landing_company';

    my $result = BOM::Pricing::v3::MarketData::trading_durations({
            language      => 'en',
            token_details => {loginid => 'dummy_malta'}});
    is $result->[0]{market}{name}, $trade_durations_malta->{market}{name}, "market name " . ($trade_durations_malta->{market}{name} // 'undefined');
    is $result->[0]{submarket}{name}, $trade_durations_malta->{submarket}{name},
        "submarket name " . ($trade_durations_malta->{submarket}{name} // 'undefined');
    cmp_deeply($result->[0]{data}[0]{trade_durations}[0], $trade_durations_malta->{data}[0]{trade_durations}[0], 'compare trading_durations');

    note 'trading_durations for default svg landing_company';
    $result = BOM::Pricing::v3::MarketData::trading_durations();
    is $result->[0]{market}{name},    $trade_durations_cr->{market}{name},    "market name $trade_durations_cr->{market}{name}";
    is $result->[0]{submarket}{name}, $trade_durations_cr->{submarket}{name}, "submarket name $trade_durations_cr->{submarket}{name}";
    cmp_deeply($result->[0]{data}[0]{trade_durations}[0], $trade_durations_cr->{data}[0]{trade_durations}[0], 'compare trading_durations');
};

done_testing;
