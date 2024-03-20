use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use BOM::Config::TradingPlatform::KycStatus;

use constant {
    MT5_COLOR_CODE => {
        red  => 255,
        none => -1,
    },
};

my $kyc_status = BOM::Config::TradingPlatform::KycStatus->new();

subtest 'get_kyc_status_list' => sub {
    my @kyc_status_list      = $kyc_status->get_kyc_status_list();
    my @expected_status_list = qw(poa_pending poa_failed poa_outdated proof_failed verification_pending needs_verification poa_rejected);
    cmp_deeply(\@kyc_status_list, bag(@expected_status_list), 'get_kyc_status_list returns the correct list of kyc statuses');
};

subtest 'get_kyc_status_color' => sub {
    my @kyc_status_red_list  = qw(poa_failed poa_outdated proof_failed verification_pending needs_verification);
    my @kyc_status_none_list = qw(poa_pending poa_rejected);
    my $color_test_list      = {
        red  => \@kyc_status_red_list,
        none => \@kyc_status_none_list,
    };

    for my $color (keys %$color_test_list) {
        for my $status (@{$color_test_list->{$color}}) {
            my $color_code = $kyc_status->get_kyc_status_color({status => $status, platform => 'mt5'});
            is($color_code, MT5_COLOR_CODE->{$color}, "Color code for $status is correct");
        }
    }

    dies_ok { $kyc_status->get_kyc_status_color({status => 'bad_status', platform => 'mt1000'}) }, 'dies when incorrect params is provided';
};

subtest 'get_kyc_cashier_permission' => sub {
    my $kyc_cashier_permission_test_list = {
        poa_pending => {
            deposit    => 1,
            withdrawal => 1
        },
        poa_failed => {
            deposit    => 1,
            withdrawal => 0
        },
        poa_outdated => {
            deposit    => 1,
            withdrawal => 0
        },
        proof_failed => {
            deposit    => 0,
            withdrawal => 0
        },
        verification_pending => {
            deposit    => 0,
            withdrawal => 0
        },
        needs_verification => {
            deposit    => 0,
            withdrawal => 0
        },
        poa_rejected => {
            deposit    => 1,
            withdrawal => 1
        },
    };

    for my $status (keys %$kyc_cashier_permission_test_list) {
        for my $operation (keys %{$kyc_cashier_permission_test_list->{$status}}) {
            my $is_enabled = $kyc_status->get_kyc_cashier_permission({status => $status, operation => $operation});
            $kyc_cashier_permission_test_list->{$status}->{$operation}
                ? ok($is_enabled,  "Cashier $operation operation is enabled for $status")
                : ok(!$is_enabled, "Cashier $operation operation is disabled for $status");

        }
    }

    dies_ok { $kyc_status->get_kyc_cashier_permission({status => 'bad_status', operation => 'bad_operation'}) },
        'dies when incorrect params is provided';
};

subtest 'get_mt5_account_color_code' => sub {
    for my $color (keys %{MT5_COLOR_CODE()}) {
        my $color_code = $kyc_status->get_mt5_account_color_code({color_type => $color});
        is($color_code, MT5_COLOR_CODE->{$color}, "Color code for $color is correct");
    }

    dies_ok { $kyc_status->get_mt5_account_color_code({color_type => 'unknown_color'}) }, 'dies when incorrect params is provided';
};

subtest 'is_kyc_cashier_disabled' => sub {
    my $kyc_cashier_disabled_test_list = {
        poa_pending          => 0,
        poa_failed           => 0,
        poa_outdated         => 0,
        proof_failed         => 1,
        verification_pending => 1,
        needs_verification   => 1,
        poa_rejected         => 0,
    };

    for my $status (keys %$kyc_cashier_disabled_test_list) {
        my $is_disabled = $kyc_status->is_kyc_cashier_disabled({status => $status});
        $kyc_cashier_disabled_test_list->{$status}
            ? ok($is_disabled,  "Cashier operation is fully disabled for $status")
            : ok(!$is_disabled, "Cashier operation is not fully disabled for $status");
    }
};

done_testing();
