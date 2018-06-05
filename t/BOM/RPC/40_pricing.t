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

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'asset_index';

my $email     = 'test@binary.com';
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email,
});
my ($token_mf) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mf->loginid);

use constant {
    # Total number of symbols listed in underlyings.yml
    NUM_TOTAL_SYMBOLS => 73,
    # Total number of volatility symbols listed in underlyings.yml
    NUM_VOLATILITY_SYMBOLS => 7,

};
# These numbers may differ from actual production output due to symbols being
#   suspended in the live platform config, which won't be included in the return.

my $entry_count_mlt = NUM_VOLATILITY_SYMBOLS;
my $entry_count_mf  = NUM_TOTAL_SYMBOLS - NUM_VOLATILITY_SYMBOLS;
my $entry_count_cr  = NUM_TOTAL_SYMBOLS;
my $first_entry_mlt = [
    "R_10",
    "Volatility 10 Index",
    [
        ["callput",      "Higher/Lower",               "5t", "365d"],
        ["callput",      "Rise/Fall",                  "5t", "365d"],
        ["touchnotouch", "Touch/No Touch",             "5t", "365d"],
        ["endsinout",    "Ends Between/Ends Outside",  "2m", "365d"],
        ["staysinout",   "Stays Between/Goes Outside", "2m", "365d"],
        ["digits",       "Digits",                     "5t", "10t"],
        ["asian",        "Asians",                     "5t", "10t"]]];
my $first_entry_cr_mf = [
    "frxAUDJPY",
    "AUD/JPY",
    [
        ["callput",      "Higher/Lower",               "1d", "365d"],
        ["callput",      "Rise/Fall",                  "5t", "365d"],
        ["touchnotouch", "Touch/No Touch",             "1d", "365d"],
        ["endsinout",    "Ends Between/Ends Outside",  "1d", "365d"],
        ["staysinout",   "Stays Between/Goes Outside", "1d", "365d"],
        ["callputequal", "Rise/Fall Equal",            "3m", "365d"]]];

subtest "$method logged in - no arg" => sub {
    my $params = {
        language => 'EN',
        token    => $token_mf,
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Binary Investments (Europe) Ltd
    # Trades everything except volatilities, so should be 106 entries and first entry should
    #   be frxAUDJPY with 5 contract types.
    is($entry_count_mf, @$result, 'correct number of entries');
    is_deeply($first_entry_cr_mf, $result->[0], 'First entry matches expected');
};

subtest "$method logged in - with arg" => sub {
    my $params = {
        language => 'EN',
        token    => $token_mf,
        args     => {landing_company => 'malta'}};
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Binary (Europe) Ltd
    # Only trades volatilities, so should be 7 entries and first entry should
    #   be R_10 with all contract categories except lookbacks.
    is($entry_count_mlt, @$result, 'correct number of entries');
    is_deeply($first_entry_mlt, $result->[0], 'First entry matches expected');
};

subtest "$method logged out - no arg" => sub {
    my $params = {
        language => 'EN',
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be Binary (C.R.) S.A.
    # Trades everything except, so should be 113 entries and first entry should
    #   be frxAUDJPY with 5 contract types.
    is($entry_count_cr, @$result, 'correct number of entries');
    is_deeply($first_entry_cr_mf, $result->[0], 'First entry matches expected');
};

subtest "$method logged out - with arg" => sub {
    my $params = {
        language => 'EN',
        args     => {landing_company => 'malta'}};
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Binary (Europe) Ltd
    # Only trades volatilities, so should be 7 entries and first entry should
    #   be R_10 with all contract categories except lookbacks.
    is($entry_count_mlt, @$result, 'correct number of entries');
    is_deeply($first_entry_mlt, $result->[0], 'First entry matches expected');
};

done_testing();

