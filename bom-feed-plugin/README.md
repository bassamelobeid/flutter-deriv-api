# bom-feed-plugin

### FeedClient

- Keeps polling from remote Redis on port `6389` for new tick
- On receive cleans up tick and make sure its valid.
- Invoke `on_tick` for all the plugins registered.
- Plugins that can be registered:
    - ExpiryQueue: it `update_queue_for_tick` for expiry queue. (is used to sell/settle expired contracts)
    - FakeListener: it should be used only in QA. Its supposed to listen to production feed data and feed it into QA just if it was coming from a provider listener.
- Runs on API, RPC, Pricer servers and Collector01

