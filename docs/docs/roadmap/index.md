# Roadmap

## Isolating Current Pricing Code

We want to isolate current pricing code from other services, so we can expose a consistent API. That's a big project and it includes the following steps:

- Move contract specific code out of `bom-pricing` into `bom` -- in progress
- Move contract specific code out of `bom-transaction` into `bom` -- research
- Design the API for the pricing service
- Design the API for the market data service
- Collaborate with feed team on Feed Service API
- Implement the gateway that would provide access to the current implementation of bom via well defined API
- Change all services that rely on `bom` to consume this API


