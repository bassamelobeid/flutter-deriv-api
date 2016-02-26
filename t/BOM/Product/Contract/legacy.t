use strict;
use warnings;

use Test::Most;
use Test::FailWarnings;
use Test::MockModule;
use File::Spec;
use JSON qw(decode_json);
use BOM::Test::Data::Utility::UnitTestMD qw(:init);
use BOM::Product::ContractFactory qw( produce_contract );

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

done_testing;
