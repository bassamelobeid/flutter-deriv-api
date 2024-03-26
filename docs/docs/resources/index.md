# Resources

## Pricer documentation in WikiJS

https://wikijs.deriv.cloud/en/engineering/trading-engineering/pricer/pricer-overview

## Our Code

- http://github.com/regentmarkets/bom -- this repo contains implementation of all our supported contract types, it relies on some other repositories that implement various bits of pricing logic
- http://github.com/regentmarkets/bom-pricing -- this repo implements current pricing service, it uses code in `bom` repo to calculate prices and just implements the code to create subscriptions and trigger pricing periodically
- http://github.com/regentmarkets/bom-transaction -- this repo currently contains some of our code, but itself belongs to another team

