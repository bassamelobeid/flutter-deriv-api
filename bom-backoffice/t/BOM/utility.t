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

my @valid_access_groups   = qw(AntiFraud CSWrite Compliance P2PWrite Payments QuantsWrite AccountsAdmin AccountsLimited);
my @invalid_access_groups = qw(RandomGroup FalseGroup);

subtest 'Write Access Groups' => sub {
    my @write_access_result = BOM::Backoffice::Utility::write_access_groups();
    for my $group (@valid_access_groups) {
        ok((grep { $_ eq $group } @write_access_result), "Write access valid for $group");
    }

    for my $group (@invalid_access_groups) {
        ok(!(grep { $_ eq $group } @write_access_result), "Write access not valid for $group");
    }
};

done_testing;

