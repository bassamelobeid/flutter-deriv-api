use strict;
use warnings;

use Test::Most;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use BOM::Test::Helper qw/test_schema build_wsapi_test/;

use await;

my $t = build_wsapi_test({
    debug    => 1,
    language => 'RU'
});
my ($req_storage, $res, $start, $end);

$res = $t->await::authorize({authorize => 'test'});
ok $res->{debug}->{time};
ok $res->{debug}->{method};

$res = $t->await::ping({ping => 1});
ok $res->{debug}->{time};
ok $res->{debug}->{method};

done_testing();
