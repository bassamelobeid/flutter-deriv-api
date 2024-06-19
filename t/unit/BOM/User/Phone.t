use strict;
use warnings;

use Test::More;
use BOM::User::Phone;

my %test_phones = (
    '008615054870058'   => '+8615054870058',
    '+8615054870058'    => '+8615054870058',
    '+44 7911 123456'   => '+447911123456',
    '00447911123456'    => '+447911123456',
    '+15417543010'      => '+15417543010',
    '0015417534010'     => '+15417534010',
    '+86 150 548 70005' => '+8615054870005',
    '+86-150-548-70005' => '+8615054870005',
);

for my $number (keys %test_phones) {
    is(BOM::User::Phone::format_phone($number), $test_phones{$number}, "number $number format ok");
}

done_testing();
