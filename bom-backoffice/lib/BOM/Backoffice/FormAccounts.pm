package BOM::Backoffice::FormAccounts;

use strict;
use warnings;
use Date::Utility;

sub DOB_YearList {
    my $curyear = Date::Utility->new->year;

    my $maxyear        = $curyear - 17;
    my $minyear        = $curyear - 100;
    my $yearOptionList = [map { {value => $_} } '', $minyear .. $maxyear];
    return @$yearOptionList if wantarray;
    return $yearOptionList;
}

sub DOB_DayList {
    return [map { {value => $_} } '', 1 .. 31];
}

sub GetSalutations {
    return ('Mr', 'Mrs', 'Ms', 'Miss');
}

1;
