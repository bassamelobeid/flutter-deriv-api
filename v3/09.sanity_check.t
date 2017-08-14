use strict;
use warnings;
use Test::More;
#use Test::NoWarnings; #
use Test::FailWarnings;

use JSON;
use Data::Dumper;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;
use await;

use utf8;

my $t = build_wsapi_test();

my $res = $t->await::sanity_check({ ping => '௰' });
is $res->{error}->{code}, 'SanityCheckFailed';
ok ref($res->{echo_req}) eq 'HASH' && !keys %{$res->{echo_req}};
test_schema('ping', $res);

# undefs are fine for some values
$t->await::ping({ ping => {key => undef} });

$res = $t->await::change_password({
            change_password => 1,
            old_password    => '௰',
            new_password    => '௰'
        });
ok $res->{error}->{code} ne 'SanityCheckFailed', 'Do not check value of password key';

$res = $t->await::sanity_check({
            change_password => 1,
            '௰_old_password' => '௰',
            new_password       => '௰'
        });
is $res->{error}->{code}, 'SanityCheckFailed', 'Should be failed if paswword key consist of non sanity symbols';

$t->finish_ok;

done_testing();
