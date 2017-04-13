use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Product::ContractFactory::Parser qw( shortcode_to_parameters );

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
    like($contract->longcode, qr/Legacy .* No further information is available/, 'Legacy bet longcode.');
    throws_ok { $contract->bid_price } qr/legacy bet type/i, 'Pricing legacy bet.';
    throws_ok { $contract->shortcode } qr/legacy bet type/i, 'Legacy bet shortcode.';

};

subtest 'SPREAD' => sub {
    my $legacy = shortcode_to_parameters('SPREADU_R_10_10_1491812187_100_15_DOLLAR', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    $legacy = shortcode_to_parameters('SPREADD_R_10_1_1491812051_25_5_POINT', 'USD');
    is($legacy->{bet_type}, 'Invalid', 'Legacy shortcode.');

    my $contract = produce_contract($legacy);
    is $contract->bet_type, 'INVALID',                                               'Invalid contract type';
    is $contract->code,     'INVALID',                                               'Invalid contract type';
    is $contract->longcode, 'Legacy contract. No further information is available.', 'correct longcode for legacy contract';
};

done_testing;
