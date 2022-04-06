use strict;
use warnings;
use Test::More;
use Test::Exception;

BEGIN {

    package TestClass;

    use Moose;
    use Finance::Underlying::Market::Types;
    use Finance::Contract;
    use BOM::Product::Types;

    has category => (
        is     => 'ro',
        isa    => 'contract_category',
        coerce => 1,
    );

}

throws_ok(
    sub { TestClass->new(category => []); },
    qr/does not pass the type constraint because: Validation failed for 'contract_category' with value ARRAY/,
    'type contraint ok'
);
lives_ok(sub { TestClass->new(category => Finance::Contract::Category->new('callput')) });
lives_ok(sub { TestClass->new(category => 'callput') }, 'coerce contract_category ok');

done_testing;
