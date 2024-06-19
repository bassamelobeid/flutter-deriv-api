use strict;
use warnings;
use Test::More;
use Test::Exception;
use Test::Deep;

use BOM::Backoffice::CommissionTool;

sub run_test_cases {
    my $provider = shift;

    # Test cases for the delete_commission subroutine
    subtest 'Test delete_commission subroutine' => sub {
        my $args1 = {
            provider        => $provider,
            account_type    => 'standard',
            commission_type => 'volume',
        };
        my $output1 = BOM::Backoffice::CommissionTool::delete_commission($args1);
        is($output1->{error}, 'symbol is required', 'Missing symbol');

        my $args2 = {
            symbol          => 'IBM',
            account_type    => 'standard',
            commission_type => 'volume',
        };
        my $output2 = BOM::Backoffice::CommissionTool::delete_commission($args2);
        is($output2->{error}, 'provider is required', 'Missing provider');

        my $args3 = {
            symbol          => 'IBM',
            provider        => $provider,
            commission_type => 'volume',
        };
        my $output3 = BOM::Backoffice::CommissionTool::delete_commission($args3);
        is($output3->{error}, 'account_type is required', 'Missing account_type');

        my $args4 = {
            symbol       => 'IBM',
            provider     => $provider,
            account_type => 'standard',
        };
        my $output4 = BOM::Backoffice::CommissionTool::delete_commission($args4);
        is($output4->{error}, 'commission_type is required', 'Missing commission_type');
    };

    # Test cases for the save_commission subroutine
    subtest 'Test save_commission subroutine' => sub {
        my $args1 = {
            provider        => $provider,
            account_type    => 'standard',
            commission_type => 'volume',
        };
        my $output1 = BOM::Backoffice::CommissionTool::save_commission($args1);
        is($output1->{error}, 'symbol is required', 'Missing symbol');

        my $args2 = {
            symbol          => 'IBM',
            account_type    => 'standard',
            commission_type => 'volume',
        };
        my $output2 = BOM::Backoffice::CommissionTool::save_commission($args2);
        is($output2->{error}, 'provider is required', 'Missing provider');

        my $args3 = {
            symbol          => 'IBM',
            provider        => $provider,
            commission_type => 'volume',
        };
        my $output3 = BOM::Backoffice::CommissionTool::save_commission($args3);
        is($output3->{error}, 'account_type is required', 'Missing account_type');

        my $args4 = {
            symbol       => 'IBM',
            provider     => $provider,
            account_type => 'standard',
        };
        my $output4 = BOM::Backoffice::CommissionTool::save_commission($args4);
        is($output4->{error}, 'commission_type is required', 'Missing commission_type');

        my $args5 = {
            symbol          => 'IBM',
            provider        => $provider,
            account_type    => 'standard',
            commission_type => 'volume',
            contract_size   => 0.1,
            commission_rate => 1,
        };
        my $output5 = BOM::Backoffice::CommissionTool::save_commission($args5);
        is($output5->{error}, 'commission_rate must be less than 1', 'Invalid commission_rate');

        my $args6 = {
            symbol          => 'IBM',
            provider        => $provider,
            account_type    => 'standard',
            commission_type => 'volume',
            contract_size   => 'a',
            commission_rate => 1,
        };
        my $output6 = BOM::Backoffice::CommissionTool::save_commission($args6);
        is($output6->{error}, 'contract_size must be numeric', 'Invalid contract_size');

        my $args7 = {
            symbol          => 'IBM',
            provider        => $provider,
            account_type    => 'standard',
            commission_type => 'volume',
            contract_size   => 1,
            commission_rate => 'a',
        };
        my $output7 = BOM::Backoffice::CommissionTool::save_commission($args7);
        is($output7->{error}, 'commission_rate must be numeric', 'Invalid commission_rate');
    };
}

subtest 'Test for provider dxtrade' => sub {
    run_test_cases('dxtrade');
};

subtest 'Test for provider ctrader' => sub {
    run_test_cases('ctrader');
};

done_testing();
