package BOM::Market::Types;

use strict;
use warnings;

use Moose;

use MooseX::Types::Moose qw(Int Num Str);
use MooseX::Types -declare => [
    map { "bom_$_" }
        qw(
        financial_market
        submarket
        market_markups
        date_object
        time_interval
        underlying_object
        )];

use Moose::Util::TypeConstraints;
use Time::Duration::Concise;

subtype 'bom_time_interval', as 'Time::Duration::Concise';
coerce 'bom_time_interval', from 'Str', via { Time::Duration::Concise->new(interval => $_) };

subtype 'bom_date_object', as 'Date::Utility';
coerce 'bom_date_object', from 'Str', via { Date::Utility->new($_) };

subtype 'bom_financial_market', as 'BOM::Market';
coerce 'bom_financial_market', from 'Str', via { return BOM::Market::Registry->instance->get($_); };

subtype 'bom_submarket', as 'BOM::Market::SubMarket';
coerce 'bom_submarket', from 'Str', via { return BOM::Market::SubMarket::Registry->instance->get($_); };

subtype 'bom_market_markups', as 'BOM::Market::Markups';
coerce 'bom_market_markups', from 'HashRef' => via { BOM::Market::Markups->new($_); };

subtype 'bom_underlying_object', as 'BOM::Market::Underlying';
coerce 'bom_underlying_object', from 'Str', via { BOM::Market::Underlying->new($_) };

no Moose;
no Moose::Util::TypeConstraints;
__PACKAGE__->meta->make_immutable;

1;
