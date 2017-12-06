package BOM::Product::ContractFactory;

use strict;
use warnings;

use Cache::RedisDB;
use List::Util qw( first );
use Time::Duration::Concise;
use VolSurface::Utils qw(get_strike_for_spot_delta);
use YAML::XS qw(LoadFile);
use File::ShareDir;
use Try::Tiny;

use Postgres::FeedDB::Spot::Tick;

use BOM::Product::Exception;
use BOM::Product::Categorizer;
use Finance::Contract::Longcode qw(
    shortcode_to_parameters
);

require UNIVERSAL::require;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
use BOM::Product::Role::Multibarrier;

use Exporter qw(import export_to_level);

BEGIN {
    our @EXPORT_OK = qw( produce_contract make_similar_contract produce_batch_contract );
}

use BOM::Product::Contract::Batch;
use BOM::Product::Contract::Asiand;
use BOM::Product::Contract::Asianu;
use BOM::Product::Contract::Call;
use BOM::Product::Contract::Calle;
use BOM::Product::Contract::Pute;
use BOM::Product::Contract::Digitdiff;
use BOM::Product::Contract::Digiteven;
use BOM::Product::Contract::Digitmatch;
use BOM::Product::Contract::Digitodd;
use BOM::Product::Contract::Digitover;
use BOM::Product::Contract::Digitunder;
use BOM::Product::Contract::Expirymisse;
use BOM::Product::Contract::Expiryrangee;
use BOM::Product::Contract::Expirymiss;
use BOM::Product::Contract::Expiryrange;
use BOM::Product::Contract::Invalid;
use BOM::Product::Contract::Notouch;
use BOM::Product::Contract::Onetouch;
use BOM::Product::Contract::Put;
use BOM::Product::Contract::Range;
use BOM::Product::Contract::Upordown;
use BOM::Product::Contract::Vanilla_call;
use BOM::Product::Contract::Vanilla_put;
use BOM::Product::Contract::Lbfixedcall;
use BOM::Product::Contract::Lbfixedput;
use BOM::Product::Contract::Lbfloatcall;
use BOM::Product::Contract::Lbfloatput;
use BOM::Product::Contract::Lbhighlow;
use BOM::Product::Contract::Binaryico;

=head2 produce_contract

Produce a Contract Object from a set of parameters

=cut

sub produce_contract {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref = {%{_args_to_ref($build_arg, $maybe_currency, $maybe_sold)}};

    unless ($params_ref->{processed}) {
        # Categorizer's process always returns ARRAYREF, and here we will have and need only one element in this array
        $params_ref = BOM::Product::Categorizer->new(parameters => $params_ref)->process()->[0];
    }

    my $product_type    = $params_ref->{product_type} // 'basic';
    my $landing_company = $params_ref->{landing_company};
    my $role            = 'BOM::Product::Role::' . ucfirst lc $product_type;
    my $role_exists     = $role->can('meta');

    # This occurs after to hopefully make it more annoying to bypass the Factory.
    $params_ref->{'_produce_contract_ref'} = \&produce_contract;

    my $contract_class = 'BOM::Product::Contract::' . ucfirst lc $params_ref->{bet_type};

    # XXX Remove this after ICO finishes
    BOM::Product::Exception->throw(error_code => 'IcoNotAllowed')
        if $contract_class->isa('BOM::Product::Contract::Coinauction')
        and $landing_company ne 'costarica';

    return _validate_input_parameters($contract_class->new($params_ref)) unless $role_exists;

    # we're applying role. For speed reasons, we're not using $role->meta->apply($contract_obj),
    # but create an anonymous class with needed role. This is done only once and cached

    $params_ref->{build_parameters}{role} = $role;
    $contract_class = Moose::Meta::Class->create_anon_class(
        superclasses => [$contract_class],
        roles        => [$role],
        cache        => 1,
    );

    return _validate_input_parameters($contract_class->new_object($params_ref));
}

sub produce_batch_contract {
    my $build_args = shift;

    $build_args->{_produce_contract_ref} = \&produce_contract;
    return BOM::Product::Contract::Batch->new(parameters => $build_args);
}

sub _validate_input_parameters {
    my $contract = shift;

    unless ($contract->is_binaryico || $contract->for_sale || $contract->is_legacy) {
        BOM::Product::Exception->throw(error_code => 'SameExpiryStartTime') if $contract->date_start->epoch == $contract->date_expiry->epoch;
        BOM::Product::Exception->throw(error_code => 'PastExpiryTime')      if $contract->date_expiry->is_before($contract->date_start);
    }

    return $contract;
}

sub _args_to_ref {
    my ($build_arg, $maybe_currency, $maybe_sold) = @_;

    my $params_ref =
          (ref $build_arg eq 'HASH') ? $build_arg
        : (defined $build_arg) ? shortcode_to_parameters($build_arg, $maybe_currency, $maybe_sold)
        :                        undef;

    # After all of that, we should have gotten a hash reference.
    die 'Improper arguments to produce_contract.' unless (ref $params_ref eq 'HASH');

    return $params_ref;
}

=head2 make_similar_contract

Produce a Contract Object from an example contract with one or more parameters changed.

The second argument should be the contract for which you wish to produce a similar contract.
The changes should be in a hashref as the second argument.

Set 'as_new' to create a similar contract which starts "now"
Set 'priced_at' to move to a particular point in the contract lifetime. 'now' and 'start' are short-cuts.
Otherwise, the changes should be attribute to fill on the contract as with produce_contract
=cut

sub make_similar_contract {
    my ($orig_contract, $changes) = @_;

    # Start by making a copy of the parameters we used to build this bet.
    my %build_parameters = %{$orig_contract->build_parameters};

    if ($changes->{as_new}) {
        if ($orig_contract->two_barriers) {
            $build_parameters{high_barrier} = $orig_contract->high_barrier->supplied_barrier if $orig_contract->high_barrier;
            $build_parameters{low_barrier}  = $orig_contract->low_barrier->supplied_barrier  if $orig_contract->low_barrier;
        } else {
            $build_parameters{barrier} = $orig_contract->barrier->supplied_barrier if (defined $orig_contract->barrier);
        }
        delete $build_parameters{date_start};
    }
    delete $changes->{as_new};
    if (my $when = $changes->{priced_at}) {
        if ($when eq 'now') {
            delete $build_parameters{date_pricing};
        } else {
            $when = $orig_contract->date_start if ($when eq 'start');
            $build_parameters{date_pricing} = $when;
        }
    }
    delete $changes->{priced_at};

    # Sooner or later this should have some more knowledge of what can and
    # should be built, but for now we use this naive parameter switching.
    foreach my $key (%$changes) {
        $build_parameters{$key} = $changes->{$key};
    }

    return produce_contract(\%build_parameters);
}

1;
