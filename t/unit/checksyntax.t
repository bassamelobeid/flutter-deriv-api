use strict;
use warnings;
use Test::More;

use BOM::Test::CheckSyntax;
use Test::Exception;
use Test::MockModule;
my $mocked = Test::MockModule->new('BOM::Test::CheckSyntax');

subtest 'run_command' => sub {
    throws_ok { BOM::Test::CheckSyntax::_run_command() } qr/command cannot be empty/;

    my @result = BOM::Test::CheckSyntax::_run_command("ls xxxx");
    ok !@result, 'empty result for wrong command';

    @result = BOM::Test::CheckSyntax::_run_command(qw/ls -U lib | sort -r/);
    is_deeply \@result, [qw/BOM await.pm/], 'get ls result';
};

subtest 'get_self_name_space' => sub {
    my @self_pm = BOM::Test::CheckSyntax::_get_self_name_space();
    is_deeply \@self_pm, ['BOM::Test'], 'check self name space for bom-test';
    $mocked->mock(_run_command => sub { return qw(lib/BOM/MarketData.pm lib/BOM/DynamicSettings.pm lib/BOM/MarketData) });
    @self_pm = BOM::Test::CheckSyntax::_get_self_name_space();
    is_deeply \@self_pm, [qw/BOM::DynamicSettings BOM::MarketData/], 'check self name space for mocked';
    $mocked->unmock;
};

subtest 'get_pm_subs' => sub {

    my $file = 'lib/BOM/Test/Rudderstack/Webserver.pm';
    my $subs = BOM::Test::CheckSyntax::_get_pm_subs($file);
    ok !$subs, "cannot find subs for $file";

    $file = 'lib/await.pm';
    $subs = BOM::Test::CheckSyntax::_get_pm_subs($file);
    my $expcted_subs = {
        'wsapi_wait_for' => {
            'end'   => 63,
            'start' => 25
        },
        'AUTOLOAD' => {
            'end'   => 94,
            'start' => 68
        },
        'get_data' => {
            'end'   => 114,
            'start' => 96
        }};
    is_deeply($subs, $expcted_subs, "check subs for $file");
};

done_testing();

