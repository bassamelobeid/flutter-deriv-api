# NAME

    BOM::Transaction

# METHODS

## `$self->_recover($error)`

This function tries to recover from an unsuccessful buy/sell.
It may decide to retry the operation. And it may decide to
sell expired bets before doing so.

#### Parameters

- `$error`
the error exception thrown by BOM::Platform::Data::Persistence::DB::\_handle\_errors

### Return Value

[Error::Base](https://metacpan.org/pod/Error::Base) object
which means an unrecoverable but expected condition has been found.
Typically that means a precondition, like sufficient balance, was
not met.

### Exceptions

In case of an unexpected error, the exception is re-thrown unmodified.

## sell\_expired\_contracts
Static function: Sells expired contracts.
For contracts with missing market data, settle them manually for real money accounts, but sell with purchase price for virtual account
Returns: HashRef, with:
'total\_credited', total amount credited to Client
'skip\_contract', count for expired contracts that failed to be sold
'failures', the failure information

# TEST

    # run all test scripts # 
    make test
    # run one script # 
    prove t/BOM/001_structure.t
    # run one script with perl # 
    perl -MBOM::Test t/BOM/001_structure.t
