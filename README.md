# binary-websocket-api

Binary WebSocket API (https://developers.binary.com)

Binary WebSocket API is asynchronous proxy JSON-RPC 2.0 server based on Mojo::WebSocketProxy.
It manages stream subscriptions using Redis channels and publishes Redis messages.
It validates every API request/response using [json schemas](https://github.com/regentmarkets/binary-websocket-api/tree/master/config/v3).
It manages parameters between RPC requests using connection stash.
It manages request rate limits using [RateLimitations::Pluggable](https://github.com/binary-com/perl-RateLimitations-Pluggable).

To run tests you need get [bom-websocket-tests](https://github.com/regentmarkets/bom-websocket-tests).

## Introspection

Binary WebSocket API proxy server also starts HTTP server for debug/monitoring poproses.
Server binds to local IP and listens on a random port, which is logged during WS API start. Port is random for reload safety.
Server waits a command to be received and sends back JSON formatted output.
Commands are:

* `connections` Returns a list of active connections.
* `subscriptions` Returns a list of all subscribed Redis channels. Placeholder, not yet implemented.
* `stats` Returns a summary of current stats.
* `dumpmem` Writes a dumpfile using [Devel::MAT::Dumper](https://metacpan.org/pod/Devel::MAT::Dumper).
* `help` Returns a list of available commands.

# TEST
    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl, you should load some modules. please refer to .proverc
    perl -MBOM::Test -MBOM::RPC::PricingRpc -MBOM::Test::Script::NotifyPub t/001_structure.t

