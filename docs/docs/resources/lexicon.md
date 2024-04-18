
# Pricing Service Lexicon

| Term    | Definition |
| -------- | ------- |
| Ask Price | The price a party is willing to accept to part with the priced asset. The pricing service will typically compute this via the theoretical price plus some markup. |
| Bid Price | The price a party is willing to pay to acquire the priced asset. The pricing service will typically compute this via the theoretical price minus some markup. |
| Client | The counterparty to contracts priced by this service. |
| Configuration Data | Proprietary Deriv-prepared data which is used to adjust pricing models and engines to better react to contemporaneous market conditions. |
| Contract | An agreement between two parties on terms of future actions. Deriv contracts are typically based on market movements and offer a future payout in exchange for an up-front staking premium from the client. |
| Market Data | Publicly available information which reflects the best known sentiments of market participants at a given time.  Being publicly available does not imply that all parties have access to the same information at the same time, merely that it can be obtained and is not inherently proprietary to Deriv. |
| Markup | Adjustments to a price which reflect our uncertainty in the pricing model under given conditions.  Markup is also used to add a profit margin. |
| Price | A currency-denominated amount for which a party is willing to exchange some other valued holding.  Prices produced by this service are expressed from the perspective of Deriv. |
| Pricing Engine | An in-code representation of a pricing model. |
| Pricing Model | Our best understanding as to how a future price is implied by given market conditions. Many of our models include proprietary Deriv innovations. |
| Pricing Request Data | Parameters particular to a client request which expresses their intent in seeking a price. This will always include, at least, a contract type.  Other data may be required depending upon the contract type.  Some may be inferred from the particular request, such as an endtime computed from a duration. |
| Quote | The underlyling price as exposed by a tick. Primarily used to reference the price in the spot. |
| Spot | The tick used to price a particular contract.  The particular market data to use in deriving the price will depend upon the identification of this tick. |
| Theoretical Price | The best estimate of a fair market price produced by a pricing model. |
| Tick | The market data on a particular underlying at a particular point in time.  It is, at a minimum, composed of an underlying identifier, the point in time and a market price. |
| Underlying | The core asset on which a contract is based.  This service can price contracts on both real world and Deriv-managed synthetic underlyings. |
| Validation | The process by which we ensure that a produced price is viable to present to a client. |
