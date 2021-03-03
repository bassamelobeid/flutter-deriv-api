use strict;
use warnings;

use Test::Most;

use BOM::Rules::Engine;

my $rule_engine = BOM::Rules::Engine->new(residence => 'id');

subtest 'rule pass' => sub {
    my $rule_name = 'pass';
    lives_ok { $rule_engine->apply_rules($rule_name) } 'This rule succeeds without context or args';
    lives_ok { $rule_engine->apply_rules($rule_name, {a => 1}) } 'It succeeds with any args';
};

done_testing;
