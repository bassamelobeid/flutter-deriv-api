use strict;
use warnings;

use Test::More;
use Test::Exception;

use BOM::Event::Actions::CustomerIO;
use BOM::Test;
use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase qw( :init );

my $user = BOM::User->create(
    email    => 'test@binary.com',
    password => BOM::User::Password::hashpw('password'));

subtest 'initialization' => sub {
    throws_ok {
        BOM::Event::Actions::CustomerIO->new
    }
    qr/Missing required arguments: user/;

    lives_ok {
        BOM::Event::Actions::CustomerIO->new(user => $user);
    }
    'Instance created successfully';
};

done_testing();
