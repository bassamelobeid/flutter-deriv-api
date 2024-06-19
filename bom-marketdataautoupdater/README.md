# bom-marketdataautoupdater

Code that pulls market data from third party systems (Bloomberg, ForexFactory) into our system. 

(1) bin/bom_update_economic_events.pl 

A script runs ForexFactory::extract_economic_events to extract economic events for 2 weeks and update economic event chronicle documents.

```
To update economic events: bin/bom_update_economic_events.pl
``` 

Source: ForexFactory

Package dependency: BOM::MarketDataAutoUpdater::UpdateEconomicEvents, ForexFactory, Quant::Framework::EconomicEventCalendar.

Frequency of this script being called: 00GMT on daily basic

Input: www.forexfactory.com

Output: category='economic_events'at Chronicle


(2) bin/update_interest_rates.pl

A script run BOM::MarketDataAutoUpdater::InterestRates to update currency interest rate. 

```
To update interest rate: bin/update_interest_rate.pl
```

Source: Bloomberg Data License

Package dependency: BOM::MarketDataAutoUpdater::InterestRates

Frequency of this script being called: 16:50GMT on daily basic. (Libor updates rate at 11:45 London time and Bloomberg updated it at 4 hours after that, hence we scheduled the run time at 17GMT to make sure we have updated rate from Bloomberg)

Input: interest rates file type from Bloomberg::FileDownloader e.g. interest_rate.csv 

Output: category='interest_rates' at Chronicle

(3) bin/update_implied_interest_rates.pl

A script run BOM::MarketDataAutoUpdater::ImpliedInterestRates to update implied interest rate. For each currency pair, to hold the interest rate parity, the rate of one the currency need to be implied from the forward rate of pair and the market rate of corresponding currency. Example: USDJPY, interest rate of JPY on this pair need to implied from the forward rate of USDJPY and the market rate of USD.


```
To update interest rate: bin/update_implied_interest_rate.pl
```

Source: Bloomberg Data License and also the market rate of correponding currency of the pair

Package dependency: BOM::MarketDataAutoUpdater::ImpliedInterestRates

Frequency of this script being called: 17GMT on daily basic. (This script must be run after bin/update_interest_rates.pl as it depends on the market interest rate of the corresponding currency of the pair).

Input: 
category='interest_rates' at Chronicle <br/>
forward rates file type from Bloomberg::FileDownloader e.g. forward_rates.csv 

Output: category='interest_rates' at Chronicle

(4) bin/update_smartfx_rate.pl

A scripts to update interest rate of smart fx based on the rate of the forex pairs of the basket.

```
To update interest rate: bin/update_implied_smartfx_rate.pl
```

Source: The market rate of the currency

Package dependency: BOM::MarketDataAutoUpdater::ImpliedInterestRates

Frequency of this script being called: 00GMT on daily basic

Input: 'interest_rates' at Chronicle <br/>
Output: 'interest_rates' at Chronicle

(5) bin/updatevol.pl

A script runs BOM::MarketDataAutoUpdater::Indices to update vol of indices and BOM::MarketDataAutoUpdater::Forex to update vol of forex and commodities

```
To update vol of indicies: bin/updatevol.pl --market=indices
To udpate vol of forex and commodities: bin/updatevol.pl
```

Source: Bloomberg Data License (Forex and Commodities), Superderivaties (Indices)

Frequency of this script being called: Hourly basic (Indices), 10min basic (Forex and commodities)

Input:
- volatility file type from Bloomberg::FileDownloaderBloomberg e.g. 
weekday vols : fxvol%02d45_points.csv, quantovol.csv
weekend vols : fxvol_wknd.csv, quantovol_wknd.csv
- volatility file type from SuperDerivatives e.g. auto_upload.xls

Output: category='volatility_surfaces' 

# TEST
    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t
