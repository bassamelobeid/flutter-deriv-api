bom-backoffice
==============

Binary.com backoffice system

Dependencies
============

This repo depends on:

* https://github.com/regentmarkets/cpan
* https://github.com/regentmarkets/bom

How to run
==========

starman bom-backoffice.psgi

Then you can access the login page at https://www.binary.com/d/backoffice/login.cgi

In QA, the following command (as root) should start a single worker with all logs going to the
console:

```
PERL5LIB=/home/git/regentmarkets/cpan/local/lib/perl5:/home/git/regentmarkets/cpan/local/lib/perl5/x86_64-linux:/home/git/regentmarkets/cpan/local/lib/perl5/x86_64-linux-gnu-thread-multi:/home/git/regentmarkets/bom/lib:/home/git/regentmarkets/bom-postgres/lib:/home/git/regentmarkets/bom-platform/lib:/home/git/regentmarkets/bom-market/lib:/home/git/regentmarkets/bom-marketdataautoupdater/lib:/home/git/regentmarkets/bom-backoffice/lib:/home/git/regentmarkets/bom-myaffiliates/lib:/home/git/regentmarkets/binary-websocket-api/lib:/home/git/regentmarkets/bom-paymentapi/lib:/home/git/regentmarkets/bom-oauth/lib:/home/git/regentmarkets/bom-rpc/lib:/home/git/regentmarkets/bom-populator/lib:/home/git/regentmarkets/bom-feed/lib:/home/git/regentmarkets/bom-test/lib:/home/git/regentmarkets/php-mt5-webapi/lib:/home/git/regentmarkets/bom-transaction/lib:/home/git/regentmarkets/bom-pricing/lib /etc/rmg/bin/perl /home/git/regentmarkets/cpan/local/bin/starman --user nobody --group nogroup --listen :82 --workers=1 --preload-app /home/git/regentmarkets/bom-backoffice/bom-backoffice.psgi
```

Errors
======

Errors go to the file named in environment variable ERROR_LOG, which defaults to error_log.

Notes
=====

Steps for a typical development session:
```
export ERROR_LOG=/var/log/httpd/bo_error.log; touch $ERROR_LOG; tail -f $ERROR_LOG
starman -r -l :82 bom-backoffice.psgi
```
The -l switch says to listen to where nginx is sending backoffice requests.

The -r switch will restart the webserver immediately on changes to a source file.

<a href="https://zenhub.io"><img src="https://raw.githubusercontent.com/ZenHubIO/support/master/zenhub-badge.png" height="18px"></a>

Update Translation
===================

### Install
* $ apt-get install gettext

### Update translation files (.po, .pot):
* Check under https://hosted.weblate.org/projects/binary-websocket/#repository if there are uncommitted changes, if any then commit them by clicking on commit.
* Lock weblate so that during update there is no conflicts
* Make sure your all repo are on master and its upto date with branch master
* In `/home/git/binary-com/translations-websockets-api`, switch to `translations` branch
* under `/home/git/regentmarkets/bom-backoffice`, run `make i18n`
* In `/home/git/binary-com/translations-websockets-api`, `*.po , .pot` files will be updated. After `git push origin translations`, new text will appear in Weblate for translation
* Once translation is done on Weblate, create PR from `translations` branch to `master` for `/home/git/binary-com/translations-websockets-api`

TEST
====

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/pricing_details.t

