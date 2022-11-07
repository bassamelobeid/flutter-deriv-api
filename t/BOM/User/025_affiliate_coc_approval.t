use strict;
use warnings;

use Test::More;
use Test::Fatal;
use Test::Deep;
use Test::Exception;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);
use BOM::User::Client;

my $email    = 'test_affiliate@binary.com';
my $password = 'Abcd1234';
my $hash_pwd = BOM::User::Password::hashpw($password);

my $user = BOM::User->create(
    email    => $email,
    password => $hash_pwd,
);

my $id_1 = 'aff123';

cmp_deeply(exception { $user->set_affiliate_coc_approval(0) }, {code => 'AffiliateNotFound'}, 'cannot set affiliate coc without affiliate_id');

is $user->affiliate_coc_approval_required, undef, 'returns undef if user is not an affiliate';

$user->set_affiliate_id($id_1);

local $SIG{__WARN__} = sub { };
cmp_deeply(exception { $user->set_affiliate_id('123') }, {code => 'AffiliateAlreadyExist'}, 'cannot change affiliate_id');

is $user->affiliate->{affiliate_id}, $id_1, 'can set affiliate_id';
is $user->affiliate->{coc_approval}, undef, 'affiliate coc approval is set to null by default';

is $user->set_affiliate_coc_approval(undef), 1, 'can set affiliate coc approval to null';
is $user->set_affiliate_coc_approval(0),     1, 'can set affiliate coc approval to false';
is $user->set_affiliate_coc_approval(1),     1, 'can set affiliate coc approval to true';

done_testing();
