use strict;
use warnings;
use utf8;
use Test::Most;
use Test::Mojo;
use Data::Dumper;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use BOM::Test::RPC::QueueClient;
use BOM::Database::Model::OAuth;
use Email::Stuffer::TestLinks;
use Test::MockModule;
use Brands;

my $mocked_brands = Test::MockModule->new('Brands');
$mocked_brands->mock('offerings_for_app', sub { return 'default' });

my $mock = Test::MockModule->new('LandingCompany::Offerings');
$mock->mock(is_asian_hours => sub { note 'mocked to non-asian hours'; return 0 });

my $c = BOM::Test::RPC::QueueClient->new();

my $email      = 'test@binary.com';
my $client_mlt = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MLT',
    email       => $email,
});
my ($token_mlt) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mlt->loginid);

use constant {
    NUM_TOTAL_SYMBOLS      => 88,    # Total number of symbols listed in underlyings.yml
    NUM_VOLATILITY_SYMBOLS => 0,     # Total number of volatility symbols listed in underlyings.yml
};

# These numbers may differ from actual production output due to symbols being
#   suspended in the live platform config, which won't be included in the return.
my $entry_count_mlt = NUM_VOLATILITY_SYMBOLS;
my $entry_count_cr  = NUM_TOTAL_SYMBOLS;
my $first_entry_mlt = [];
my $first_entry_cr  = [
    "frxAUDJPY",
    "AUD/JPY",
    [
        ["callput",       "Higher/Lower",               "1d", "365d"],
        ["callput",       "Rise/Fall",                  "5t", "365d"],
        ["touchnotouch",  "Touch/No Touch",             "1d", "365d"],
        ["endsinout",     "Ends Between/Ends Outside",  "1d", "365d"],
        ["staysinout",    "Stays Between/Goes Outside", "1d", "365d"],
        ["callputequal",  "Rise/Fall Equal",            "3m", "365d"],
        ["callputspread", "Call Spread/Put Spread",     "3m", "2h"],
    ]];

my $first_entry_cr_mf_test2 = [
    "frxAUDJPY",
    "AUD/JPY",
    [
        ["callput",       "Higher/Lower",               "1d", "365d"],
        ["callput",       "Rise/Fall",                  "5t", "365d"],
        ["touchnotouch",  "Touch/No Touch",             "1d", "365d"],
        ["endsinout",     "Ends Between/Ends Outside",  "1d", "365d"],
        ["staysinout",    "Stays Between/Goes Outside", "1d", "365d"],
        ["callputequal",  "Rise/Fall Equal",            "3m", "365d"],
        ["callputspread", "Call Spread/Put Spread",     "3m", "2h"],
        ["multiplier",    "Multiply Up/Multiply Down",  "",   ""],       # logged out will be default to virtual
    ]];

sub _test_asset_index {
    my ($params, $count, $first_entry) = @_;

    return sub {
        my $result = $c->call_ok('asset_index', $params)->has_no_system_error->has_no_error->result;
        is(0 + @$result,    $count,            'correct number of entries');
        is($result->[0][0], $first_entry->[0], 'First entry item 1 is asset code');
        is($result->[0][1], $first_entry->[1], 'First entry item 2 is asset name/description');
        cmp_deeply($result->[0][2] // [], bag(@{$first_entry->[2]}), 'First entry item 3 lists available contract types');
        return undef;
    };
}

# Result should be for Deriv (Europe) Limited
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

# Result should be Deriv (SVG) LLC
# Trades everything except, so should be 113 entries and first entry should
#   be frxAUDJPY with 5 contract types.
subtest "asset_index logged out - no arg" => _test_asset_index({language => 'EN'}, $entry_count_cr, $first_entry_cr_mf_test2);

# Result should be for Deriv (Europe) Limited
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
