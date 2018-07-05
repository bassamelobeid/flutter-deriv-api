# bom-myaffiliates

This repo contains:

* Integration code with MyAffiliates system API
* crons for generating Myaffiliates's related data, eg: client registration, revenue, commission, etc.

It provides `binary_myaffiliates` service, which setup Mojo App for serving request to pull client's daily registration & activities.
API endpoints are:

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
