use strict;
use warnings;

use Test::More;

use BOM::Test::Helper::CTC qw(create_loginid);

subtest 'create_loginid' => sub {
    is create_loginid(), 'id_1', 'Create first loginid';
    is create_loginid(), 'id_2', 'Create second loginid';
};

done_testing;
