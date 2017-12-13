# Overview

A Mojolicious-based RPC server that accepts method calls encoded in JSON over (http? websocket? something custom??)


# Background

 * Mojolicious
 * Mojolicious::Commands
 * MojoX::JSON::RPC


# Files

 * `bin/binary_rpc.pl` - container script, initial start point

   Just runs the `BOM::RPC` app via `Mojolicious::Commands->start_app`

 * `lib/BOM/RPC.pm` - dispatch root.

   Implements monitoring metrics on elapsed time, CPU and memory usage of each call.

 * `lib/BOM/RPC/Registry.pm` - map RPC names to handler code

   Stores the mapping from RPC names to (anonymous) functions that implement the behaviour of the RPCs.
   Also implements a keyword-like DSL to ease implementation of RPCs in other modules.

 * `lib/BOM/RPC/v3/...` - implement RPCs

   The bulk of the code in this repository is the actual implementation of RPC handling functions.
   These live in individual files that populate names within the `BOM::RPC::v3::...` namespace.


# Lifecycle

## Startup

 1. Mojolicious calls `BOM::RPC->startup`

 2. `startup()` builds a map of method names to handler functions for them and invokes the `json_rpc_dispatcher` Mojolicious plugin

 3. `startup()` sets up before/after dispatch hooks to implement monitoring metrics around each RPC request

At this point, control returns to the Mojolicious core where it awaits incoming requests.


## Request Handling

 1. Requests arrive over HTTP(?) and begin being processed by `MojoX::JSON::RPC`

 2. `MojoX::JSON::RPC` will invoke the handling code that had been registered for the method.

    This code is typically one of the methods found in one of the `.pm` files under the `BOM::RPC::v3::` namespace.
