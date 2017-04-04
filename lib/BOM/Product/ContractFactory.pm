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

use BOM::Platform::Context qw(request);
use BOM::Product::Categorizer;
use BOM::Product::ContractFactory::Parser qw(
    shortcode_to_parameters
);

require UNIVERSAL::require;

use BOM::MarketData qw(create_underlying_db);
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;

use base qw( Exporter );

our @EXPORT_OK = qw( produce_contract make_similar_contract produce_batch_contract );

# pre-load modules
require BOM::Product::Contract::Batch;
require BOM::Product::Contract::Asiand;
require BOM::Product::Contract::Asianu;
require BOM::Product::Contract::Call;
require BOM::Product::Contract::Calle;
require BOM::Product::Contract::Pute;
require BOM::Product::Contract::Digitdiff;
require BOM::Product::Contract::Digiteven;
require BOM::Product::Contract::Digitmatch;
require BOM::Product::Contract::Digitodd;
require BOM::Product::Contract::Digitover;
require BOM::Product::Contract::Digitunder;
require BOM::Product::Contract::Expirymisse;
require BOM::Product::Contract::Expiryrangee;
require BOM::Product::Contract::Expirymiss;
require BOM::Product::Contract::Expiryrange;
require BOM::Product::Contract::Invalid;
require BOM::Product::Contract::Notouch;
require BOM::Product::Contract::Onetouch;
require BOM::Product::Contract::Put;
require BOM::Product::Contract::Range;
require BOM::Product::Contract::Spreadd;
require BOM::Product::Contract::Spreadu;
require BOM::Product::Contract::Upordown;
require BOM::Product::Contract::Vanilla_call;
require BOM::Product::Contract::Vanilla_put;

=head2 produce_contract

Produce a Contract Object from a set of parameters

=cut

my $contract_type_config = LoadFile(File::ShareDir::dist_file('LandingCompany', 'contract_types.yml'));
{
    my %loaded = ();

    sub produce_contract {
        my ($build_arg, $maybe_currency, $maybe_sold) = @_;

        my $params_ref = {%{_args_to_ref($build_arg, $maybe_currency, $maybe_sold)}};

        unless ($params_ref->{processed}) {
            $params_ref = BOM::Product::Categorizer->new(parameters => $params_ref)->process();
        }

        # load it first
        my $landing_company = $params_ref->{landing_company};
        # We have 'japan-virtual' as one of the landing companies: remap this to a valid Perl class name
        # Can't change the name to 'japanvirtual' because we have db functions tie to the original name.
        $landing_company =~ s/-//;
        my $role = 'BOM::Product::Role::' . ucfirst lc $landing_company;
        # We'll cache positive + negative results here, and we don't expect files to appear/disappear
        # after startup so we don't ever clear the cache.
        unless (exists $loaded{$role}) {
            # Ignoring the return of try on purpose: we just want to know whether the file exists
            $loaded{$role} = try { $role->require } || 0;
        }
        $params_ref->{build_parameters}{role} = $role if $loaded{$role};

        # This occurs after to hopefully make it more annoying to bypass the Factory.
        $params_ref->{'_produce_contract_ref'} = \&produce_contract;

        my $contract_class = 'BOM::Product::Contract::' . ucfirst lc $params_ref->{bet_type};
        my $contract_obj   = $contract_class->new($params_ref);
        # apply it here.
        $role->meta->apply($contract_obj) if $loaded{$role};

        return $contract_obj;
    }

    sub produce_batch_contract {
        my $build_args = shift;

        $build_args->{_produce_contract_ref} = \&produce_contract;
        return BOM::Product::Contract::Batch->new(parameters => $build_args);
    }
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
        if (!$orig_contract->is_spread) {
            if ($orig_contract->two_barriers) {
                $build_parameters{high_barrier} = $orig_contract->high_barrier->supplied_barrier if $orig_contract->high_barrier;
                $build_parameters{low_barrier}  = $orig_contract->low_barrier->supplied_barrier  if $orig_contract->low_barrier;
            } else {
                $build_parameters{barrier} = $orig_contract->barrier->supplied_barrier if (defined $orig_contract->barrier);
            }
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
