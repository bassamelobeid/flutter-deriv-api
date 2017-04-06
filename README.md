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

# METHODS - Date attributes

## date\_start

For American contracts, defines when the contract starts.

For Europeans, this is used to determine the barrier when the requested barrier is relative.

## date\_pricing

The date at which we're pricing the contract. Provide ` undef ` to indicate "now".

## date\_expiry

When the contract expires.

## date\_settlement

When the contract was settled (can be `undef`).

## effective\_start

- For backpricing, this is ["date\_start"](#date_start).
- For a forward-starting contract, this is ["date\_start"](#date_start).
- For all other states - i.e. active, non-expired contracts - this is ["date\_pricing"](#date_pricing).

# METHODS - Other attributes

## duration

The requested contract duration, specified as a string indicating value with units.
The unit is provided as a single character suffix:

- t - ticks
- s - seconds
- m - minutes
- h - hours
- d - days

Examples would be ` 5t ` for 5 ticks, ` 3h ` for 3 hours.

## for\_sale

Was this bet built using BOM-generated parameters, as opposed to user-supplied parameters?

Be sure, as this allows us to relax some checks. Don't relax too much, as this still came from a
user at some point.. and they are wily.

This will contain the shortcode of the original bet, if we built it from one.

## max\_tick\_expiry\_duration

A TimeInterval which expresses the maximum time a tick trade may run, even if there are missing ticks in the middle.

# METHODS

## is\_after\_settlement

This check if the contract already passes the settlement time

For tick expiry contract, it can expires when a certain number of ticks is received or it already passes the max\_tick\_expiry\_duration.
For other contracts, it can expires when current time has past a pre-determined settelement time.

## is\_after\_expiry

This check if the contract already passes the expiry times

For tick expiry contract, there is no expiry time, so it will check again the exit tick
For other contracts, it will check the remaining time of the contract to expiry.

## get\_time\_to\_expiry

Returns a TimeInterval to expiry of the bet. For a forward start bet, it will NOT return the bet lifetime, but the time till the bet expires.

If you want to get the contract life time, use:

    $contract->get_time_to_expiry({from => $contract->date_start})

## get\_time\_to\_settlement

Like get\_time\_to\_expiry, but for settlement time rather than expiry.

## longcode

Returns the (localized) longcode for this contract.

May throw an exception if an invalid expiry type is requested for this contract type.

## allowed\_slippage

Ratio of slippage we allow for this contract, where 0.01 is 1%.
