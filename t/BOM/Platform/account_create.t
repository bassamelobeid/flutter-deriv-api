use Test::More;
use Test::Exception;
use BOM::Platform::Account::Virtual;
use BOM::Platform::MyAffiliates::TrackingHandler;

$lives = &lives_ok;
$dies = &dies_ok;

my @accounts = (
   {
     expect    => $lives,
     email     => 'foo@test.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => $lives,
     email     => 'foo@binary.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => $dies, # duplicate
     email     => 'foo@test.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => $lives,
     email     => 'foo2@binary.com',
     password  => 'foobar',
     residence => 'Canada',
   },
   {
     expect    => $lives,
     email     => 'foo@testing.com',
     password  => 'foobar',
     residence => 'Indonesia',
   },
   {
     expect    => $lives,
     email     => 'foo@test123.com',
     password  => 'foobar',
     residence => 'Antarctica',
   },
     
);

$_->{expect}(sub {
        ok(BOM::Platform::Account::Virtual::create_account({
            %$_,
            aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
        }));
}) for @accounts;

done_testing;
