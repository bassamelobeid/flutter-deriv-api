bom-backoffice
==============

Binary.com backoffice system

Dependencies
============

This repo depends on:

* https://github.com/regentmarkets/cpan
* https://github.com/regentmarkets/bom-utility
* https://github.com/regentmarkets/bom
* https://github.com/regentmarkets/binary-static-backoffice

How to run
==========

starman bom-backoffice.psgi

Then you can access the login page at https://www.binary.com/d/backoffice/login.cgi

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
