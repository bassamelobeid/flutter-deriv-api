use Test::Most 0.22 (tests => 4);
use Test::MockTime qw(set_relative_time);
use Test::NoWarnings;
use YAML::XS qw(DumpFile LoadFile);

use BOM::Market::UnderlyingDB;

my $udb;
lives_ok {
    $udb = BOM::Market::UnderlyingDB->instance();
}
'Initialized';

subtest 'bbdl_parameters' => sub {
    subtest 'Simple fetch' => sub {
        my $bbdl_parameters;
        lives_ok {
            $bbdl_parameters = $udb->bbdl_parameters;
        }
        'Got the BBDL Parameters, without killing myself';

        ok $bbdl_parameters, 'BBDL parameters are actually there';
        ok $bbdl_parameters->{AEX}, 'Has AEX';
        is $bbdl_parameters->{AEX}->{region}, 'europe', 'AEX has europe region';
    };

    subtest 'Fancy filter' => sub {
        my $bbdl_parameters;
        lives_ok {
            $bbdl_parameters = $udb->bbdl_parameters('I Like ice cream');
        }
        'I am bullet proof, do not die when I get nonsense input';

        ok !$bbdl_parameters, 'Filter is not a hashref';
    };
};

subtest 'bbdl_bom_mapping_for' => sub {
    subtest 'Simple Mapping' => sub {
        my $mapping;
        lives_ok {
            $mapping = $udb->bbdl_bom_mapping_for;
        };

        is ref $mapping, 'HASH', 'Isa hash';
        is $mapping->{'AEX Index'}, 'AEX', 'AEX is mapped to AEX Index';

        is $mapping->{'INDU Index'}, 'DJI', 'DJI is mapped to INDU Index';
    };

};

