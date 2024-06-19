package BOM::MarketData::Types;

use strict;
use warnings;

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [qw(underlying_object)];

use Moose::Util::TypeConstraints;
use BOM::MarketData qw(create_underlying);

subtype 'underlying_object', as 'Quant::Framework::Underlying';
coerce 'underlying_object', from 'Str', via { create_underlying($_) };

no Moose;
no Moose::Util::TypeConstraints;
__PACKAGE__->meta->make_immutable;

1;
