use strict;
use warnings;

use Test::NoLeaks;
use Test::More;
use Test::MockModule;
use BOM::Platform::Account::Virtual;
use BOM::Config::Runtime;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Config;

my $on_production = 1;
my $config_mocked = Test::MockModule->new('BOM::Config');
$config_mocked->mock('on_production', sub { return $on_production });

my $passes_count = 0;
test_noleaks(
    code => sub {
        $passes_count++;
        my $account = BOM::Platform::Account::Virtual::create_account({
                details => {
                    email           => 'leak-test@binary.com',
                    client_password => 'does-not-matter',
                    residence       => 'US',
                }});
        BAIL_OUT("expectations does not met")
            unless $account->{error}->{code} eq 'invalid residence';
    },
    track_memory  => 1,
    track_fds     => 1,
    passes        => 1024,
    warmup_passes => 1,
    tolerate_hits => 1,
);

done_testing;
