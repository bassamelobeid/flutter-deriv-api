use Test::More;
use Test::Exception;
use BOM::Platform::Account::Virtual;
use BOM::Platform::MyAffiliates::TrackingHandler;

my @accounts = (
   {
     email     => 'foo@test.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     email     => 'foo@binary.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     email     => 'foo2@binary.com',
     password  => 'foobar',
     residence => 'Canada',
   },
   {
     email     => 'foo@testing.com',
     password  => 'foobar',
     residence => 'Indonesia',
   },
   {
     email     => 'foo@test123.com',
     password  => 'foobar',
     residence => 'Antarctica',
   },
);

lives_ok( sub {
ok(BOM::Platform::Account::Virtual::create_account({
        details => {
            %$_,
            aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
            env => 'testing',
        }}), "$_->{email} created") 
}, "$_->{email} lives") for @accounts;

done_testing;
