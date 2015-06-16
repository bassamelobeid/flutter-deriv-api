use strict;
use warnings;
use Test::More;
use Test::Exception;

BEGIN {

    package TestClass;

    use Moose;
    use BOM::Product::Contract::Category;
    use BOM::Product::Types;

    has category => (
        is     => 'ro',
        isa    => 'bom_contract_category',
        coerce => 1,
    );

}

throws_ok(
    sub { TestClass->new(category => []); },
    qr/does not pass the type constraint because: Validation failed for 'bom_contract_category' with value ARRAY/,
    'type contraint ok'
);
lives_ok(sub { TestClass->new(category => BOM::Product::Contract::Category->new('callput')) });
lives_ok(sub { TestClass->new(category => 'callput') }, 'coerce bom_contract_category ok');

done_testing;
