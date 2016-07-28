use Test::Most 0.22 (tests => 3);
use Test::Warn;

use BOM::Platform::Runtime::AppConfig;
use BOM::Platform::Runtime;

my $app_config;
lives_ok {
    $app_config = BOM::Platform::Runtime::AppConfig->new();
}
'We are living';

ok($app_config->system->isa('BOM::Platform::Runtime::AppConfig::Attribute::Section'), 'system is a Section');
is_deeply($app_config->quants->underlyings->suspend_trades, [], "suspendonlytrades is empty by default");
