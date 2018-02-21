use strict;
use warnings;

use Test::Exception;
use Test::Memory::Cycle;
use Test::More qw( no_plan );
use Test::Warn;
use Test::MockModule;
use File::Spec;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use Data::Hash::DotNotation;
use BOM::Product::ContractFactory qw( produce_contract );
use BOM::Test::Data::Utility::UnitTestMarketData qw( :init );

my $recorded_date = Date::Utility->new;

#Cycle test will complain because of data types it cannot handle (Redis's Socket has these data types)
#So we just ignore those complaints here
$SIG{__WARN__} = sub { my $w = shift; return if $w =~ /^Unhandled type: GLOB/; die $w; };

subtest 'Check BOM::Product::Contract for memory cycles' => sub {
    use_ok('BOM::Product::Contract');
    my $params = {
        underlying => 'frxEURUSD',
        duration   => '10t',
        bet_type   => 'CALL',
        barrier    => 'S0P',
        payout     => 100,
        currency   => 'USD',
    };

    BOM::Test::Data::Utility::UnitTestMarketData::create_doc(
        'volsurface_delta',
        {
            symbol        => 'frxEURUSD',
            recorded_date => Date::Utility->new(),
        });

    my $bet = produce_contract($params);

    isa_ok($bet, 'BOM::Product::Contract', 'Able to create representative bet.');
    eval_all_moose_attributes($bet);

    memory_cycle_ok($bet, 'Bet does not have memory cycles after attribute access.');
};

subtest 'Check Quant::Framework::Underlying for memory cycles' => sub {
    use_ok('Quant::Framework::Underlying');

    my @examples = (['frxUSDJPY'], ['frxEURGBP', Date::Utility->today]);

    foreach my $example (@examples) {
        my $underlying = create_underlying(@{$example});

        isa_ok($underlying, 'Quant::Framework::Underlying', 'Able to create representative underlying.');
        eval_all_moose_attributes($underlying);

        memory_cycle_ok($underlying, 'Underlying does not have memory cycles after attribute access.');
    }
};

sub eval_all_moose_attributes {

    my ($obj) = shift;

    # Exercise all of the attributes we can find.
    foreach my $attr ($obj->meta->get_all_attributes) {
        my $which = $attr->name;
        eval { $obj->$which; };    # Some of these may throw exceptions
    }

    return 1;
}

