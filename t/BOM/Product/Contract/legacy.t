use strict;
use warnings;

use Test::Most;
use Test::Warnings;
use Test::MockModule;
use File::Spec;
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );
use Finance::Contract::Longcode qw( shortcode_to_parameters );

subtest 'BOM::Product::Contract::Invalid' => sub {
    use_ok('BOM::Product::Contract::Invalid');
};

subtest 'General.' => sub {
    plan tests => 4;

    my $contract_params = {
        bet_type    => 'DOUBLECONTRA',
        date_expiry => '13-Feb-08',
        date_start  => 1200614400,
        underlying  => 'frxUSDJPY',
        payout      => 1,
        currency    => 'USD',
        barrier     => 108.26,
    };

    my $contract = produce_contract($contract_params);

    isa_ok $contract, 'BOM::Product::Contract::Invalid';
    is_deeply($contract->longcode, ['Legacy contract. No further information is available.']);

    throws_ok { $contract->bid_price } qr/BOM::Product::Exception/, 'Pricing legacy bet.';
    throws_ok { $contract->shortcode } qr/BOM::Product::Exception/, 'Legacy bet shortcode.';

};

subtest 'SPREAD' => sub {
    my $legacy = shortcode_to_parameters('SPREADU_R_10_10_1491812187_100_15_DOLLAR', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    $legacy = shortcode_to_parameters('SPREADD_R_10_1_1491812051_25_5_POINT', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $contract = produce_contract($legacy);
    is $contract->bet_type, 'INVALID', 'Invalid contract type';
    is $contract->code,     'INVALID', 'Invalid contract type';
    is_deeply($contract->longcode, ['Legacy contract. No further information is available.']);
};

done_testing;
