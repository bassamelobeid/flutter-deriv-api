### The endpoint
```js
shortcode = "DIGITMATCH_R_10_18.18_1613451832_5T_7_0"
currency  = "USD"

// endpoint:
`GET /v1/${currency}/${shortcode}`
```

- The api starts with `/v1/`.
- The only required parameters are `shortcode` and `currency`.
- We have explicitly decided not to support **back pricing** in this endpoint.
- A future endpoint will have an extra `date_pricing` parameter, to support back pricing.
