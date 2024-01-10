# bom-myaffiliates

This repo contains:

* Integration code with MyAffiliates system API
* crons for generating Myaffiliates's related data, eg: client registration, revenue, commission, etc.

Based on final changes we just save CSV files as backup in our servers using Mojo App for serving request to pull client's daily registration & activities. Same files will send over SFTP to myaffiliates every day (when Cron calls).

Mojo app API endpoint examples (on our servers not myaffilaite side):

- Activity report: <https://collector01.binary.com/myaffiliates/activity_report?date=2016-05-30>
- Registration: <https://collector01.binary.com/myaffiliates/registration?date=2016-05-30>
- Turnover: <https://collector01.binary.com/myaffiliates/turnover_report?date=2016-05-30>

# Main Dependencies
CPAN module: WebService::MyAffiliates

# TEST
    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t


# Code Scope

We have cronjobs for generating and sending daily csv reports like `Acitivity of users`, `registration`, `multiplier` and `lookback` and `TurnOver` to MyAffiliate thirdparty to calculate commisions. This scripts located in `cron` folder:  
`/home/git/regentmarkets/bom-myaffiliates/cron`

Also the chef instructions for these cronjobs located in `chef` repository `binary_crons` recepies :

`/home/git/regentmarkets/chef/cookbooks/binary_crons/recipes/myaffiliate.rb`.

Main Function that Send Files through SFTP is in `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/SFTP.pm`.   

Two important things exists in above code. `/etc/rmg/third_party.yml` should be updated for connecting to SFTP server and also the `FTP_PATH` for SFTP is set to `/myaffiliates/bom/data/data2/` ( In order to check it with Devops on SFTP server)

# Activity Report (PL)

This report has these columns:

* `date`: The date report generated ( that means when cronjob runs everyday in this case)
* `client_loginid`: Loginid of the client. If the report is for `Deriv` Brand then it has `deriv_` prefix before the actual loginid like `deriv_CR00001`. otherwise for `Binary` we only have the loginid like: `CR00001` this is also true for all other type of reports.
* `company_profit_loss`: It is known as `PnL` or `Profit & Loss` it is accumulation value of profit/Loss for specific client.
* `deposit`: Amount of deposit in the whole day for the specific client
* `turnover_ticktrade`: ticktrade fo turnover
* `intraday_turnover`: turnover within the day
* `other_turnover`: other turnover values
* `first_funded_date`: Date of first fund in account
* `withdrawals`: Ammount of all withrawals in single day
* `first_funded_amount`: First value that client funded in his account
* `exchange_rate`: Rate using for calculation

For more detail about the code and calculation please look at `lib` directory: `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/ActivityReporter.pm`  


Sample of csv file for date `2023-09-14` file: `pl_2023-09-14_deriv.csv`

| date       | client_loginid | company_profit_loss | deposits | turnover_ticktrade | intraday_turnover | other_turnover | first_funded_date | withdrawals | first_funded_amount | exchange_rate |
|------------|----------------|---------------------|----------|---------------------|-------------------|---------------|-------------------|-------------|---------------------|--------------|
| 2023-09-14 | deriv_CR00001 | 0.00                | 10.00    | 0.00                | 0.00              | 0.00          | 2023-09-14        | 0.00        | 0.00                | 1.00         |
| 2023-09-14 | deriv_CR00002 | 0.00                | 28.00    | 0.00                | 0.00              | 0.00          | 2023-09-14        | 0.00        | 0.00                | 1.00         |
| 2023-09-14 | deriv_CR00003 | 0.00                | 0.00     | 0.00                | 0.00              | 0.00          | 2023-09-14        | 0.00        | 0.00                | 1.00         |
| 2023-09-14 | deriv_CR00004 | 0.00                | 5.26     | 0.00                | 0.00              | 0.00          | 2023-09-14        | 0.00        | 0.00                | 1.00         |
| 2023-09-14 | deriv_CR00005 | 0.00                | 50.00    | 0.00                | 0.00              | 0.00          | 2023-09-14        | 0.00        | 0.00                | 1.00         |


# Registration Report

For registration we only have three columns:

* `Date`: the date report generated
* `Loginid`: Loginid of the client
* `AffiliateToken`: Value of affiliate token that assigned to the client.


For more detail about the code and calculation please look at `lib` directory: `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/GenerateRegistrationDaily.pm`  

Sample of csv file for date `2023-09-14` file: `registration_2023-09-14.csv`

| Date       | Loginid        | AffiliateToken  |
|------------|----------------|-----------------|
| 2023-09-14 | deriv_CR0001   | S_57GRW....     |
| 2023-09-14 | deriv_CR0002   | myzrhcO....     |
| 2023-09-14 | deriv_CR0003   | lSzlZw5B...     |
| 2023-09-14 | deriv_CR0004   | Ze-Jyhi...      |

# Turnover Report

This report has these colmns:

* `Date`
* `Loginid`
* `Stake`
* `PayoutPrice`
* `Probability`
* `ReferenceId`
* `ExchangeRate`

For more detail about the code and calculation please look at `lib` directory: `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/TurnoverReporter.pm`  

Sample of csv file for date `2023-09-11` file: `turnover_2023-09-11.csv`


| Date       | Loginid        | Stake | PayoutPrice | Probability | ReferenceId | ExchangeRate |
|------------|----------------|-------|-------------|-------------|-------------|--------------|
| 2023-09-11 | deriv_CR0001 | 0.50  | 0.96        | 52.08       | 5555555  | 1.00         |
| 2023-09-11 | deriv_CR0002 | 4.00  | 7.97        | 50.19       | 4444444  | 1.00         |
| 2023-09-11 | deriv_CR0003 | 1.07  | 2.10        | 50.95       | 3333333  | 1.00         |
| 2023-09-11 | deriv_CR0004 | 0.66  | 1.28        | 51.56       | 2222222  | 1.00         |
| 2023-09-11 | deriv_CR0005 | 1.00  | 1.95        | 51.28       | 1111111  | 1.00         |

# Lookback Report

Lookback has these columns:

* `Date`
* `Client Login ID`
* `Stake`
* `Lookback Commission`
* `Exchange Rate`

For more detail about the code and calculation please look at `lib` directory: `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/LookbackReporter.pm`

Sample:

| Date       | Client Login ID | Stake | Lookback Commission | Exchange Rate |
|------------|-----------------|-------|----------------------|--------------|
| 2023-09-14 | deriv_CR000001  | 0.30  | 0.00                 | 1.00         |


# Multiplier Report

These are the columns for Multiplier:

* Date
* Client Login ID
* Trade Commission
* Commission
* Exchange Rate

For more detail about the code and calculation please look at `lib` directory: `/home/git/regentmarkets/bom-myaffiliates/lib/BOM/MyAffiliates/MultiplierReporter.pm`


| Date       | Client Login ID | Trade Commission | Commission | Exchange Rate |
|------------|-----------------|-------------------|------------|--------------|
| 2023-09-10 | deriv_CR000001  | 0.44              | 0.17       | 1.00         |
| 2023-09-10 | deriv_CR000002  | 0.13              | 0.05       | 1.00         |
| 2023-09-10 | deriv_CR000003  | 0.06              | 0.02       | 1.00         |


# Manually upload a report for a single or multiple dates to MyAffiliate SFTP server

In rare cases if you want to upload already generated csv file from our servers (collector01) to MyAffiliate SFTP server you should pair with Devops. They are able to ssh to `collector01` and create a bash file containing the following lines for specific date (please change date and month accordingly for your needs)

For activity report (because the report file names on collector01 server is `pl` we generate a separate script for them):
```bash
year=2023    # <- change this if you want
month=10     # <- month 10 = October
for brand in deriv binary; do   # <- you can add brand here or reomve them
  for action in activity; do  #
    for day in {01..30}; do  # <- change days accordingly. this will do from first to 30th of the month
      perl -MBOM::MyAffiliates::SFTP -wle "BOM::MyAffiliates::SFTP::send_csv_via_sftp('/db/myaffiliates/$brand/pl_$year-$month-$day.csv', '$action', '$brand')"
      echo "Uploaded $action data for $brand on $year-$month-$day"
    done
  done
done
```

For other types of report you can use this sample just like above ( just file names are different):

```bash
year=2023
month=10
for brand in deriv binary; do
  for action in registrations lookback turnover multiplier; do
    for day in {01..02}; do
      if [ "$brand" = "binary" ] && [ "$action" = "multiplier" ]; then
        continue  # Skip "multiplier" for the "binary" brand
      fi
      perl -MBOM::MyAffiliates::SFTP -wle "BOM::MyAffiliates::SFTP::send_csv_via_sftp('/db/myaffiliates/$brand/${action}_$year-$month-$day.csv', '$action', '$brand')"
      echo "Uploaded $action data for $brand on $year-$month-$day"
    done
  done
done
```


# Connect to SFTP server for MyAffiliates (DevOps needed)
If you are going to communicate with a Devops that has MyAffiliates SFTP, you should know that we Already have at least **two** different accounts with different permissions (`bom_data` that only have access to MT5 and `bom_data2` that have full access to all directories `binary`, `deriv` and more)


---
Beware of entering host. you should add `sftp://` to first of your host like `sftp://ftp.myaffili....` otherwise you will get errors like this:
