#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More tests => 1;
use Test::Deep;

use BOM::Platform::Runtime;
use BOM::Platform::LandingCompany::Registry;

my $all = [qw(
        ASIANU
        ASIAND
        CALL
        PUT
        DIGITDIFF
        DIGITMATCH
        DIGITOVER
        DIGITUNDER
        DIGITEVEN
        DIGITODD
        EXPIRYMISS
        EXPIRYRANGE
        RANGE
        UPORDOWN
        ONETOUCH
        NOTOUCH
        SPREADU
        SPREADD
        )];
my $no_spreads = [qw(
        ASIANU
        ASIAND
        CALL
        PUT
        DIGITDIFF
        DIGITMATCH
        DIGITOVER
        DIGITUNDER
        DIGITEVEN
        DIGITODD
        EXPIRYMISS
        EXPIRYRANGE
        RANGE
        UPORDOWN
        ONETOUCH
        NOTOUCH
        )];
my $japan = [qw(
        CALLE
        PUT
        EXPIRYMISS
        EXPIRYRANGEE
        RANGE
        UPORDOWN
        ONETOUCH
        NOTOUCH
        )];
subtest 'legal allowed contract categories' => sub {
    for (qw(VRTC CR MLT MX)) {
        my $cc = BOM::Platform::LandingCompany::Registry::get_by_broker($_ . '123123')->legal_allowed_contract_types;
        cmp_bag($cc, $all, $_ . ' has all contract categories');
    }
    my $cc = BOM::Platform::LandingCompany::Registry::get_by_broker('MF123123')->legal_allowed_contract_types;
    cmp_bag($cc, $no_spreads, 'MF has contract categories except spreads');
    for (qw(VRTJ JP)) {
        my $cc = BOM::Platform::LandingCompany::Registry::get_by_broker($_ . '123123')->legal_allowed_contract_types;
        cmp_bag($cc, $japan, $_ . ' has equal european contract categories');
    }
};
