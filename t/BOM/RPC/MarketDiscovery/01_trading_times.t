use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $method = 'trading_times';
my $params = {language => 'ZH_CN'};
my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
is_deeply(['markets'], [keys %$result] 'have markets key');
diag Dumper $result->{markets}[0];

