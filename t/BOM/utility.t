use strict;
use warnings;

use Test::More;
use Test::Fatal;

use BOM::Backoffice::Utility qw(master_live_server_error get_languages);

can_ok(main => qw(master_live_server_error get_languages));

is(
    exception {
        my $languages = get_languages();
        is($languages->{EN}, 'English',    'found English');
        is($languages->{ID}, 'Indonesian', 'found Indonesian');
    },
    undef,
    'no exceptions from get_languages'
);
done_testing;

