use Test::MockTime qw( restore_time set_absolute_time );
use Test::Most;
use Test::MockModule;

use BOM::MarketDataAutoUpdater::Flat;
use Quant::Framework::VolSurface;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::FeedTestDatabase   qw(:init);

my $fake_date = Date::Utility->new('2022-12-10 15:55:55');
set_absolute_time($fake_date->epoch);

our %save_result;

my $mocked = Test::MockModule->new('Quant::Framework::VolSurface');
$mocked->mock('save' => sub { my $calss = shift; $calss = ref $calss; $save_result{$calss} += 1; });

my $au = BOM::MarketDataAutoUpdater::Flat->new();

BOM::Test::Data::Utility::FeedTestDatabase::create_realtime_tick({
        underlying => $_,
        epoch      => $fake_date->epoch,
        quote      => 100
    }) for @{$au->symbols_for_moneyness};

lives_ok { $au->run } 'run without dying';

my $symbols_for_delta = [
    'frxAUDAED', 'frxAUDTRY', 'frxCADCHF', 'frxCADJPY', 'frxCHFJPY', 'frxEURAED', 'frxEURTRY', 'frxFKPUSD', 'frxGBPAED', 'frxGBPTRY',
    'frxGIPUSD', 'frxNZDCHF', 'frxSHPUSD', 'frxUSDAED', 'frxUSDAFN', 'frxUSDALL', 'frxUSDAMD', 'frxUSDAOA', 'frxUSDARS', 'frxUSDAWG',
    'frxUSDAZM', 'frxUSDBAM', 'frxUSDBBD', 'frxUSDBDT', 'frxUSDBHD', 'frxUSDBIF', 'frxUSDBMD', 'frxUSDBND', 'frxUSDBOB', 'frxUSDBRL',
    'frxUSDBSD', 'frxUSDBTN', 'frxUSDBWP', 'frxUSDBYR', 'frxUSDBZD', 'frxUSDCDF', 'frxUSDCLP', 'frxUSDCNY', 'frxUSDCOP', 'frxUSDCRC',
    'frxUSDCUP', 'frxUSDCVE', 'frxUSDDJF', 'frxUSDDKK', 'frxUSDDOP', 'frxUSDDZD', 'frxUSDECS', 'frxUSDEGP', 'frxUSDERN', 'frxUSDETB',
    'frxUSDFJD', 'frxUSDGEL', 'frxUSDGHC', 'frxUSDGMD', 'frxUSDGNF', 'frxUSDGQE', 'frxUSDGTQ', 'frxUSDGYD', 'frxUSDHNL', 'frxUSDHTG',
    'frxUSDIQD', 'frxUSDISK', 'frxUSDJMD', 'frxUSDJOD', 'frxUSDKES', 'frxUSDKGS', 'frxUSDKHR', 'frxUSDKMF', 'frxUSDKRW', 'frxUSDKWD',
    'frxUSDKYD', 'frxUSDKZT', 'frxUSDLAK', 'frxUSDLBP', 'frxUSDLKR', 'frxUSDLRD', 'frxUSDLSL', 'frxUSDLYD', 'frxUSDMAD', 'frxUSDMDL',
    'frxUSDMGA', 'frxUSDMGF', 'frxUSDMKD', 'frxUSDMMK', 'frxUSDMNT', 'frxUSDMOP', 'frxUSDMUR', 'frxUSDMVR', 'frxUSDMWK', 'frxUSDMZM',
    'frxUSDNAD', 'frxUSDNGN', 'frxUSDNIO', 'frxUSDNPR', 'frxUSDOMR', 'frxUSDPAB', 'frxUSDPEN', 'frxUSDPGK', 'frxUSDPHP', 'frxUSDPKR',
    'frxUSDQAR', 'frxUSDRWF', 'frxUSDSAR', 'frxUSDSBD', 'frxUSDSCR', 'frxUSDSDG', 'frxUSDSLL', 'frxUSDSOS', 'frxUSDSRD', 'frxUSDSTD',
    'frxUSDSVC', 'frxUSDSZL', 'frxUSDTJS', 'frxUSDTMT', 'frxUSDTND', 'frxUSDTOP', 'frxUSDTRL', 'frxUSDTRY', 'frxUSDTTD', 'frxUSDTWD',
    'frxUSDTZS', 'frxUSDUAH', 'frxUSDUGX', 'frxUSDUYU', 'frxUSDUZS', 'frxUSDVEB', 'frxUSDVND', 'frxUSDWST', 'frxUSDXAF', 'frxUSDXCD',
    'frxUSDXOF', 'frxUSDXPF', 'frxUSDYER', 'frxUSDYUM', 'frxUSDZMK', 'frxUSDZWD', 'CL_BRENT',  'WTI_OIL',   'frxBROAUD', 'frxBROEUR',
    'frxBROGBP', 'frxBROUSD', 'frxXPDAUD', 'frxXPTAUD', 'WLDAUD',    'WLDEUR',    'WLDGBP',    'WLDUSD',    'WLDXAU'
];

is_deeply($au->symbols_for_delta, $symbols_for_delta, 'symbols_for_delta matches');

my $symbols_for_moneyness = ['ADSMI', 'DFMGI', 'EGX30', 'ISEQ', 'JCI', 'SASEIDX'];
is_deeply($au->symbols_for_moneyness, $symbols_for_moneyness, 'symbols_for_moneyness matches');

my $all_symbols = $au->all_symbols;
isa_ok $all_symbols->[0], 'Quant::Framework::Underlying', 'all_symbols is ARRAYREF of Quant::Framework::Underlying';

my $save_expected = {
    'Quant::Framework::VolSurface::Moneyness' => 6,
    'Quant::Framework::VolSurface::Delta'     => 149
};

is_deeply(\%save_result, $save_expected, 'Quant::Framework::VolSurface saved results');

restore_time();
done_testing;
