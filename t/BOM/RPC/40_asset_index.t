use strict;
use warnings;
use utf8;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC::Transport::HTTP')->app->ua);

my $email     = 'test@binary.com';
my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    email       => $email,
});
my ($token_mlt) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);

use constant {
    NUM_TOTAL_SYMBOLS      => 75,    # Total number of symbols listed in underlyings.yml
    NUM_VOLATILITY_SYMBOLS => 7,     # Total number of volatility symbols listed in underlyings.yml
};

# These numbers may differ from actual production output due to symbols being
#   suspended in the live platform config, which won't be included in the return.
my $entry_count_mlt = NUM_VOLATILITY_SYMBOLS;
my $entry_count_cr  = NUM_TOTAL_SYMBOLS;
my $first_entry_mlt = [
    "R_10",
    "Volatility 10 Index",
    [
        ["callput",       "Higher/Lower",               "5t",  "365d"],
        ["callput",       "Rise/Fall",                  "1t",  "365d"],
        ["touchnotouch",  "Touch/No Touch",             "5t",  "365d"],
        ["endsinout",     "Ends Between/Ends Outside",  "2m",  "365d"],
        ["staysinout",    "Stays Between/Goes Outside", "2m",  "365d"],
        ["digits",        "Digits",                     "1t",  "10t"],
        ["asian",         "Asians",                     "5t",  "10t"],
        ["reset",         "Reset Call/Reset Put",       "5t",  "2h"],
        ["callputspread", "Call Spread/Put Spread",     "15s", "365d"],
        ["highlowticks",  "High/Low Ticks",             "5t",  "5t"],
        ["lookback",      "Lookbacks",                  "1m",  "30m"],
        ["callputequal",  "Rise/Fall Equal",            "1t",  "1d"],
    ]];
my $first_entry_cr = [
    "frxAUDJPY",
    "AUD/JPY",
    [
        ["callput",      "Higher/Lower",               "1d", "365d"],
        ["callput",      "Rise/Fall",                  "5t", "365d"],
        ["touchnotouch", "Touch/No Touch",             "1d", "365d"],
        ["endsinout",    "Ends Between/Ends Outside",  "1d", "365d"],
        ["staysinout",   "Stays Between/Goes Outside", "1d", "365d"],
        ["callputequal", "Rise/Fall Equal",            "3m", "365d"]]];

sub _test_asset_index {
    my ($params, $count, $first_entry) = @_;

    return sub {
        my $result = $c->call_ok('asset_index', $params)->has_no_system_error->has_no_error->result;
        is(0 + @$result,    $count,            'correct number of entries');
        is($result->[0][0], $first_entry->[0], 'First entry item 1 is asset code');
        is($result->[0][1], $first_entry->[1], 'First entry item 2 is asset name/description');
        cmp_deeply($result->[0][2], bag(@{$first_entry->[2]}), 'First entry item 3 lists available contract types');
        return undef;
    };
}


# Result should be for Binary (Europe) Ltd
# Only trades volatilities, so should be 7 entries and first entry should
#   be R_10 with all contract categories except lookbacks.
subtest "asset_index logged in - with arg" => _test_asset_index({
        language => 'EN',
        token    => $token_mlt,
        args     => {landing_company => 'malta'}
    },
    $entry_count_mlt,
    $first_entry_mlt,
);

# Result should be Binary (SVG) Ltd.
# Trades everything except, so should be 113 entries and first entry should
#   be frxAUDJPY with 5 contract types.
subtest "asset_index logged out - no arg" => _test_asset_index({language => 'EN'}, $entry_count_cr, $first_entry_cr);

# Result should be for Binary (Europe) Ltd
# Only trades volatilities, so should be 7 entries and first entry should
#   be R_10 with all contract categories except lookbacks.
subtest "asset_index logged out - with arg" => _test_asset_index({
        language => 'EN',
        args     => {landing_company => 'malta'}
    },
    $entry_count_mlt,
    $first_entry_mlt,
);

done_testing();
