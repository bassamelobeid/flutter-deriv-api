#!/etc/rmg/bin/perl
use strict;
use warnings;
use Test::More;
use Test::Exception;
use BOM::Backoffice::GNUPlot;
use Data::Dumper;
use feature 'say';
use utf8;

local $ENV{'REMOTE_ADDR'} = defined($ENV{'REMOTE_ADDR'}) ? $ENV{'REMOTE_ADDR'} : '127.0.0.1';
local $ENV{'TEST_TMPDIR'} = '/home/git/regentmarkets/bom-backoffice/t/BOM';

my $object1 = BOM::Backoffice::GNUPlot->new();

is(defined $object1,                          1, 'BOM::Backoffice:GNUPlot->new() should return an object');
is($object1->isa('BOM::Backoffice::GNUPlot'), 1, 'object returned is of class BOM::Backoffice:GNUPlot');

is($object1->is_valid_graph_type(),          undef, 'is_valid_graph_type method returns null if passed nothing');
is($object1->is_valid_graph_type(),          undef, 'it returns null if passed nothing');
is($object1->is_valid_graph_type(''),        undef, 'it returns null if passed an empty string');
is($object1->is_valid_graph_type('scatter'), undef, 'it returns null if passed an invalid graph type');
#is($object1->is_valid_graph_type('STEPS'),undef,'it is case sensitive');
is($object1->is_valid_graph_type('financebars'), 1, 'will naturally handle an expected value');

can_ok($object1, qw(set_data_properties set_graph_tmpfile set_image_properties));

dies_ok { $object1->set_data_properties({graph_type => 'pie'}) } "invalid graph type passed to set_data_properties";
dies_ok { $object1->set_data_properties } "should fail when undefined values are passed to set_data_properties";

#is($object1->set_data_properties({graph_type=>'financebars', data=>'surplus',using=>3}), 'ok', 'not sure what should happen');

done_testing();

