use Test::More;
use Test::Exception;
use BOM::Platform::Account::Virtual;
use BOM::Platform::MyAffiliates::TrackingHandler;

my @accounts = (
   {
     expect    => 'lives',
     email     => 'foo@test.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => 'lives',
     email     => 'foo@binary.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => 'dies', # duplicate
     email     => 'foo@test.com',
     password  => 'foobar',
     residence => 'United States',
   },
   {
     expect    => 'lives',
     email     => 'foo2@binary.com',
     password  => 'foobar',
     residence => 'Canada',
   },
   {
     expect    => 'lives',
     email     => 'foo@testing.com',
     password  => 'foobar',
     residence => 'Indonesia',
   },
   {
     expect    => 'lives',
     email     => 'foo@test123.com',
     password  => 'foobar',
     residence => 'Antarctica',
   },
     
);

lives_ok( sub {
ok(BOM::Platform::Account::Virtual::create_account({
            %$_,
            aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
        }), "$_->{email} created") 
}, "$_->{email} lives") for grep { $_->{expect} eq 'lives' } @accounts;

dies_ok( sub {
BOM::Platform::Account::Virtual::create_account({
            %$_,
            aff_token => BOM::Platform::MyAffiliates::TrackingHandler->new->myaffiliates_token,
})
}, "$_->{email} lives") for grep { $_->{expect} eq 'dies' } @accounts;

done_testing;
