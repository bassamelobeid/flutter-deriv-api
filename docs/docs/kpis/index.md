## KPIs and OKRs

It is very difficult, at present, to define proper KPIs for our work.  All of
the current potential metrics have a zero baseline.  This makes determining a
proper level for any such metric a more or less boolean choice.  We have either
created something which is now generating a baseline metric or we have not.

The key parameters that we monitor are on the [Pricing Subsystem dashboard](https://app.datadoghq.com/dashboard/8u5-s2a-4rk/pricing-subsystem?fromUser=false&refresh_mode=sliding&view=spans&from_ts=1716116672725&to_ts=1716289472725&live=true) in DataDog, but we do not expect to see any improvements on those in the medium term.

As such, it is more productive to focus on OKRs for the current period.  Pricing
services require access to configuration data, market data and pricing request
data.

The team is working on projects which enable us to leverage existing sources of
data as well as creating new services to provide data which is otherwise hidden
in the monolithic legacy code.  The projects we expect to complete in the near
term include:

- Chronicle reader to extract market data from the existing systems
    - Current status: In progress
    - Challenges: proper testing for correctness against production data
- Offerings service to support contract routing and validation
    - Current status: In testing
- Pricer configuration import to tune pricers as done in legacy perl
    - Current status: In progress
    - Needs: conversion to an importable Go module
- Volatility reader
    - Current status: planning
    - Blocking on: chronicle reader
    - Challenges: proper API for surface v. smile v. point
- Pricing service for accumulators to price this specific contract type
    - Current status: planning
    - Blocking on: offerings service
    - Challenges: pricing an accumulator has a different output than most contracts.

On this final challenge it is worth noting that *today* the determination of
accumulator barriers is in the purview of the Contract. The barriers act as the
effective ask price for an accumulator with its fixed stake. This feedback
from pricing to contract parameters differs from other contracts where the
stake is allowed to vary while the other pricing parameters are held constant.
