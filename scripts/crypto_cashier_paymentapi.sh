#!/bin/bash

source /etc/profile.d/perl5.sh
[ ! -d "/var/run/bom-daemon/" ] && mkdir /var/run/bom-daemon/ && chown -R nobody:nogroup /var/run/bom-daemon/
exec /home/git/regentmarkets/cpan/local/bin/hypnotoad -f /home/git/regentmarkets/bom-platform/bin/crypto_cashier_paymentapi.pl
