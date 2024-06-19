# NAME

BOM::Product::Contract - represents a contract object for a single bet

# SYNOPSIS

    use feature qw(say);
    use BOM::Product::ContractFactory qw(produce_contract);
    # Create a simple contract
    my $contract = produce_contract({
        bet_type => 'CALLE',
        duration => '5t',
    });
    # Show the current prices (as of now, since an explicit pricing date is not provided)
    say "Bid for CALLE:  " . $contract->bid_price;
    say "Ask for CALLE:  " . $contract->ask_price;
    # Get the contract with the opposite bet type, in this case a PUT
    my $opposite = $contract->opposite_contract;
    say "Bid for PUT:    " . $opposite->bid_price;
    say "Ask for PUT:    " . $opposite->ask_price;

# DESCRIPTION

This class is the base definition for all our contract types. It provides behaviour common to all contracts,
and defines the standard API for interacting with those contracts.

# ATTRIBUTES - Construction

These are the parameters we expect to be passed when constructing a new contract.
These would be passed to ["produce\_contract" in BOM::Product::ContractFactory](https://metacpan.org/pod/BOM::Product::ContractFactory#produce_contract).

## underlying

The underlying asset, as a [Finance::Underlying] instance.

# ATTRIBUTES - Other

## for\_sale

Was this bet built using BOM-generated parameters, as opposed to user-supplied parameters?

Be sure, as this allows us to relax some checks. Don't relax too much, as this still came from a
user at some point.. and they are wily.

This will contain the shortcode of the original bet, if we built it from one.

# METHODS - Boolean checks

## is\_after\_expiry

This check if the contract already passes the expiry times

For tick expiry contract, there is no expiry time, so it will check again the exit tick
For other contracts, it will check the remaining time of the contract to expiry.

## is\_after\_settlement

This check if the contract already passes the settlement time

For tick expiry contract, it can expires when a certain number of ticks is received or it already passes the max\_tick\_expiry\_duration.
For other contracts, it can expires when current time has past a pre-determined settelement time.

## is\_expired

Returns true if this contract is expired.

It is expired only if it passes the expiry time time and has valid exit tick.

## is\_legacy

True for obsolete contract types, see [BOM::Product::Contract::Invalid](https://metacpan.org/pod/BOM::Product::Contract::Invalid).

## is\_settleable

Returns true if the contract is settleable.

To be able to settle, it need pass the settlement time and has valid exit tick

# METHODS - Other

## code

Alias for ["bet\_type"](#bet_type).

TODO should be removed.

## debug\_information

Pricing engine internal debug information hashref.

## entry\_spot

The entry spot price of the contract.

## entry\_spot\_epoch

The entry spot epoch of the contract.

## expiry\_type

The expiry type of a contract (daily, tick or intraday).

## expiry\_daily

Returns true if this is not an intraday contract.

## date\_settlement

When the contract was settled (can be `undef`).

## get\_time\_to\_settlement

Like get\_time\_to\_expiry, but for settlement time rather than expiry.

## longcode

Returns the longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

## allowed\_slippage

Ratio of slippage we allow for this contract, where 0.01 is 1%.

## extra\_info

get the extra pricing information of the contract.

\->extra\_info('string'); # returns a string of information separated by underscore
\->extra\_info('arrayref'); # returns an array reference of information

# TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t
