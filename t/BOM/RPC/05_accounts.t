use Test::Most;
use Test::Mojo;
use TestUts;
use MojoX::JSON::RPC::Client;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $t = Test::Mojo->new('BOM::RPC');

my $c = MojoX::JSON::RPC::Client->new( ua => $t->app->ua);

sub test_call{
  my @args = @_;
  TestUts::test_call($c,@args);
}

test_call('/payout_currencies',{client_loginid => 'CR0021'},{result => 1}, 'test');
done_testing();
