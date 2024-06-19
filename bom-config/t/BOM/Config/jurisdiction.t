use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::Exception;
use BOM::Config::TradingPlatform::Jurisdiction;

my $jurisdiction_config = BOM::Config::TradingPlatform::Jurisdiction->new();

subtest 'get_verification_required_jurisdiction_list' => sub {
    my @jurisdiction_list          = $jurisdiction_config->get_verification_required_jurisdiction_list();
    my @expected_jurisdiction_list = qw(bvi vanuatu labuan maltainvest);
    cmp_deeply(
        \@jurisdiction_list,
        bag(@expected_jurisdiction_list),
        'get_verification_required_jurisdiction_list returns the correct list of jurisdictions'
    );
};

subtest 'get_jurisdiction_list_with_grace_period' => sub {
    my @jurisdiction_list          = $jurisdiction_config->get_jurisdiction_list_with_grace_period();
    my @expected_jurisdiction_list = qw(bvi vanuatu);
    cmp_deeply(
        \@jurisdiction_list,
        bag(@expected_jurisdiction_list),
        'get_jurisdiction_list_with_grace_period returns the correct list of jurisdictions'
    );
};

subtest 'get_jurisdiction_grace_period' => sub {
    my $grace_period_test_list = {
        bvi     => 10,
        vanuatu => 5,
    };

    for my $jurisdiction (keys %$grace_period_test_list) {
        my $grace_period = $jurisdiction_config->get_jurisdiction_grace_period($jurisdiction);
        is($grace_period, $grace_period_test_list->{$jurisdiction}, "Grace period of $grace_period days for $jurisdiction is correct");
    }

    dies_ok { $jurisdiction_config->get_jurisdiction_grace_period('non_existent_jurisdiction') }, 'dies when non-existent jurisdiction is provided';
};

subtest 'get_jurisdiction_proof_requirement' => sub {
    my $proof_requirement_test_list = {
        bvi         => [qw(poi)],
        vanuatu     => [qw(poi)],
        labuan      => [qw(poi poa)],
        maltainvest => [qw(poi poa)],
    };

    for my $jurisdiction (keys %$proof_requirement_test_list) {
        my @proof_requirements = $jurisdiction_config->get_jurisdiction_proof_requirement($jurisdiction);
        cmp_deeply(\@proof_requirements, bag(@{$proof_requirement_test_list->{$jurisdiction}}), "Proof requirements for $jurisdiction is correct");
    }
};

done_testing();
