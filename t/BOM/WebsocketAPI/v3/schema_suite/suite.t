use strict;
use warnings;
use Test::Most;
use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../../lib";
use TestHelper qw/test_schema build_mojo_test/;
use Test::MockModule;

use BOM::Database::Model::OAuth;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::Test::Data::Utility::AuthTestDatabase qw(:init);
use File::Slurp;

my $stash  = {};
my $module = Test::MockModule->new('Mojolicious::Controller');
$module->mock(
    'stash',
    sub {
        my (undef, @params) = @_;
        if (@params > 1 || ref $params[0]) {
            my $values = ref $params[0] ? $params[0] : {@params};
            @$stash{keys %$values} = values %$values;
        }
        Mojo::Util::_stash(stash => @_);
    });

my $t = build_mojo_test();

my @lines = File::Slurp::read_file( 'suite.conf' );

foreach my $line(@lines) {
	my ($send_file, $receive_file) = split(',', $line);
	note("Running [$send_file, $receive_file]\n"); 

	my $json = JSON::from_json(File::Slurp::read_file('config/v3'.$send_file));
	$t = $t->send_ok({json => $json})->message_ok;
	my $result = decode_json($t->message->[1]);

	_test_schema($receive_file, $result);	
}



sub _test_schema {
    my ($schema_file, $data) = @_;

    my $validator = JSON::Schema->new(JSON::from_json(File::Slurp::read_file("config/3/$schema_file", format => \%JSON::Schema::FORMATS)));
    my $result    = $validator->validate($data);
    ok $result, "$schema_file response is valid";
    if (not $result) {
        diag Dumper(\$data);
        diag " - $_" foreach $result->errors;
    }
}
