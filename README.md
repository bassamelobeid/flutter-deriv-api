# Overview

A Redis-based (as main) and a Mojolicious-based (as fallback) RPC servers that accept method calls encoded in JSON over:

- Mojolicious uses `http` (https://github.com/regentmarkets/bom-rpc/blob/master/lib/BOM/RPC/Transport/HTTP.pm)
- Redis uses `Consumer Groups` (https://github.com/regentmarkets/bom-rpc/blob/master/lib/BOM/RPC/Transport/Redis.pm)


# Background

 * Redis Stream and Consumer Groups (https://redis.io/topics/streams-intro)
 * Mojolicious
 * Mojolicious::Commands
 * MojoX::JSON::RPC

# Files

 * `bin/binary_rpc_redis.pl` - container script, initial start point

   Spins up the RPC workers (`BOM::RPC::Transport::Redis`) via `ForkManager`

 * `lib/BOM/RPC.pm` - dispatch root.

   Implements monitoring metrics on elapsed time, CPU and memory usage of each call.

 * `lib/BOM/RPC/Registry.pm` - map RPC names to handler code

   Stores the mapping from RPC names to (anonymous) functions that implement the behaviour of the RPCs.
   Also implements a keyword-like DSL to ease implementation of RPCs in other modules.

 * `lib/BOM/RPC/v3/...` - implement RPCs

   The bulk of the code in this repository is the actual implementation of RPC handling functions.
   These live in individual files that populate names within the `BOM::RPC::v3::...` namespace.

 * `t/schema_suite/...` - JSON-based end-to-end tests

   Use `BOM::Test::Suite::DSL` to end-to-end test RPC methods by sending and receiving JSON strings

 * `t/schema_suite/config/...` - sample JSON strings used by schema tests

 * `t/BOM/RPC/...` - unit tests for RPC methods

   These can generally invoke RPC-handling functions more directly than via JSON RPC, and may set up mocked environments or other test fixtures.


# Lifecycle

## Startup

 1. ForkManager calls `BOM::RPC::Transport::Redis->run(...)` per worker

 2. `run(...)` initializes Redis connection, builds a map of method names to handler functions for them, start listening to the specified stream.
 
 3. once new message received, `dispatch_request(...)` get called to handle request and receiving result and then push it back to the specified Redis channel.

## Request Handling

 1. Requests arrive over Redis Stream as a message and begin being processed by RPC Queue workers

 2. Workers will invoke the handling code that had been registered for the method by passing requests parameter.

    This code is typically one of the methods found in one of the `.pm` files under the `BOM::RPC::v3::` namespace.


# Testing

To run all test scripts:

```
$ make test
```

To run one script:

```
$ prove t/BOM/001_structure.t
```

To run one script with perl:

```
$ perl -It/lib -MBOM::Test -MBOM::Test::RPC::BinaryRpcRedis -MBOM::Test::RPC::PricingRpc t/BOM/001_structure.t
```
