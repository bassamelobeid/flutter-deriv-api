# binary-websocket-api

Binary WebSocket API (https://developers.binary.com)

Binary WebSocket API is asynchronous proxy JSON-RPC 2.0 server based on Mojo::WebSocketProxy.
It manages stream subscriptions using Redis channels and publishes Redis messages.
It validates every API request/response using [json schemas](https://github.com/regentmarkets/binary-websocket-api/tree/master/config/v3).
It manages parameters between RPC requests using connection stash.
It manages request rate limits using [RateLimitations::Pluggable](https://github.com/binary-com/perl-RateLimitations-Pluggable).

To run tests you need get [bom-websocket-tests](https://github.com/regentmarkets/bom-websocket-tests).

