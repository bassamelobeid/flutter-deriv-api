use Test::Most;
use Test::FailWarnings;
use Test::Trap;
use Path::Tiny;

use BOM::Market::GBM;

my @available_random_symbols = BOM::Market::UnderlyingDB->instance->get_symbols_for(
    market            => 'volidx',
    contract_category => 'ANY'
);
my $way_back_epoch = 1e9;

my $tmpfeeddir = Path::Tiny->tempdir;
$tmpfeeddir->child('random')->mkpath;

BOM::Platform::Runtime->instance->app_config->system->directory->feed("$tmpfeeddir");

subtest 'Not trying to open nonexistent Feed file' => sub {
    for my $tick (@available_random_symbols) {
        my $tick_info;
        my $underlying = BOM::Market::Underlying->new($tick);
        trap {
            $tick_info = BOM::Market::GBM::_latest_tick_info($underlying);
        };
        if ($trap->leaveby eq 'return') {
            is(ref($tick_info), 'HASH', "Spot HASHREF returned ok");
        } elsif ($trap->leaveby eq 'die') {
            like($trap->die, qr/Cannot find latest quote for|Quote for/, "Expected die message");
        } else {
            fail;
        }
    }
};

done_testing;
