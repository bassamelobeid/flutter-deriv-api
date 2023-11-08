use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::Deep;

use BOM::Backoffice::CommissionTool;

# Test cases for the save_commission subroutine
subtest 'Test save_commission subroutine' => sub {

    # Test 1: Missing symbol
    my $args1 = {
        provider        => 'dxtrade',
        account_type    => 'standard',
        commission_type => 'volume',
    };
    my $output1 = BOM::Backoffice::CommissionTool::delete_commission($args1);
    is($output1->{error}, 'symbol is required', 'Missing symbol');

    # Test 2: Missing provider
    my $args2 = {
        symbol          => 'IBM',
        account_type    => 'standard',
        commission_type => 'volume',
    };
    my $output2 = BOM::Backoffice::CommissionTool::delete_commission($args2);
    is($output2->{error}, 'provider is required', 'Missing provider');

    # Test 3: Missing account_type
    my $args3 = {
        symbol          => 'IBM',
        provider        => 'Provider1',
        commission_type => 'volume',
    };
    my $output3 = BOM::Backoffice::CommissionTool::delete_commission($args3);
    is($output3->{error}, 'account_type is required', 'Missing account_type');

    # Test 4: Missing commission_type
    my $args4 = {
        symbol       => 'IBM',
        provider     => 'dxtrade',
        account_type => 'standard',
    };
    my $output4 = BOM::Backoffice::CommissionTool::delete_commission($args4);
    is($output4->{error}, 'commission_type is required', 'Missing commission_type');

};

done_testing();
