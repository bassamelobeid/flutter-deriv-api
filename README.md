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
These would be passed to ["produce\_contract" in BOM::Product::ContractFactory](http://search.cpan.org/perldoc?BOM::Product::ContractFactory#produce\_contract).

## currency

The currency in which this contract is bought/sold, e.g. `USD`.

## payout

Payout amount value, see ["currency"](#currency).

## shortcode

(optional) This can be provided when creating a contract from a shortcode. If not, it will
be populated from the contract parameters.

## underlying

The underlying asset, as a [Finance::Asset::Underlying](http://search.cpan.org/perldoc?Finance::Asset::Underlying) instance.

# ATTRIBUTES - Date-related

## date\_expiry

When the contract expires.

## date\_pricing

The date at which we're pricing the contract. Provide ` undef ` to indicate "now".

## date\_start

For American contracts, defines when the contract starts.

For Europeans, this is used to determine the barrier when the requested barrier is relative.

## duration

The requested contract duration, specified as a string indicating value with units.
The unit is provided as a single character suffix:

- t - ticks
- s - seconds
- m - minutes
- h - hours
- d - days

Examples would be ` 5t ` for 5 ticks, ` 3h ` for 3 hours.

# ATTRIBUTES - Tick-expiry contracts

These are only valid for tick contracts.

## tick\_expiry

A boolean that indicates if a contract expires after a pre-specified number of ticks.

## prediction

Prediction (for tick trades) is what client predicted would happen.

## tick\_count

Number of ticks in this trade.

# ATTRIBUTES - Other

## starts\_as\_forward\_starting

This attribute tells us if this contract was initially bought as a forward starting contract.
This should not be mistaken for is\_forwarding\_start attribute as that could change over time.

## for\_sale

Was this bet built using BOM-generated parameters, as opposed to user-supplied parameters?

Be sure, as this allows us to relax some checks. Don't relax too much, as this still came from a
user at some point.. and they are wily.

This will contain the shortcode of the original bet, if we built it from one.

# ATTRIBUTES - From contract\_types.yml

## id

## pricing\_code

## display\_name

## sentiment

## other\_side\_code

## payout\_type

## payouttime

# METHODS - Boolean checks

## is\_after\_expiry

This check if the contract already passes the expiry times

For tick expiry contract, there is no expiry time, so it will check again the exit tick
For other contracts, it will check the remaining time of the contract to expiry.

## is\_after\_settlement

This check if the contract already passes the settlement time

For tick expiry contract, it can expires when a certain number of ticks is received or it already passes the max\_tick\_expiry\_duration.
For other contracts, it can expires when current time has past a pre-determined settelement time.

## is\_atm\_bet

Is this contract meant to be ATM or non ATM at start?
The status will not change throughout the lifetime of the contract due to differences in offerings for ATM and non ATM contracts.

## is\_expired

Returns true if this contract is expired.

It is expired only if it passes the expiry time time and has valid exit tick.

## is\_legacy

True for obsolete contract types, see [BOM::Product::Contract::Invalid](http://search.cpan.org/perldoc?BOM::Product::Contract::Invalid).

## is\_settleable

Returns true if the contract is settleable.

To be able to settle, it need pass the settlement time and has valid exit tick

## is\_spread

Returns true if this is a spread contract - due to be removed.

# METHODS - Proxied to [BOM::Product::Contract::Category](http://search.cpan.org/perldoc?BOM::Product::Contract::Category)

Our `category` attribute provides several helper methods:

## supported\_expiries

Which expiry durations we allow. Values can be:

- intraday
- daily
- tick

## supported\_start\_types

(removed)

## is\_path\_dependent

True if this is a path-dependent contract.

## allow\_forward\_starting

True if we allow forward starting for this contract type.

## two\_barriers

True if the contract has two barriers.

## barrier\_at\_start

The starting barrier value.

## category\_code

The code for this category.

# METHODS - Time-related

## timeinyears

Contract duration in years.

## timeindays

Contract duration in days.

# METHODS - Other

## debug\_information

Pricing engine internal debug information hashref.

## ticks\_to\_expiry

Number of ticks until expiry of this contract. Defaults to one more than tick\_count,
TODO JB - this is overridden in the digit/Asian contracts, any idea why?

## entry\_spot

The entry spot price of the contract.

## entry\_spot\_epoch

The entry spot epoch of the contract.

## effective\_start

- For backpricing, this is ["date\_start"](#date\_start).
- For a forward-starting contract, this is ["date\_start"](#date\_start).
- For all other states - i.e. active, non-expired contracts - this is ["date\_pricing"](#date\_pricing).

## expiry\_type

The expiry type of a contract (daily, tick or intraday).

## expiry\_daily

Returns true if this is not an intraday contract.

## date\_settlement

When the contract was settled (can be `undef`).

## get\_time\_to\_expiry

Returns a TimeInterval to expiry of the bet. For a forward start bet, it will NOT return the bet lifetime, but the time till the bet expires.

If you want to get the contract life time, use:

    $contract->get_time_to_expiry({from => $contract->date_start})

## get\_time\_to\_settlement

Like get\_time\_to\_expiry, but for settlement time rather than expiry.

## longcode

Returns the longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

## allowed\_slippage

Ratio of slippage we allow for this contract, where 0.01 is 1%.
