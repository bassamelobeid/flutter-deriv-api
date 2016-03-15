use strict;
use warnings;
use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $c      = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
my $method = 'trading_times';
my $params = {language => 'ZH_CN'};
my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
ok($result->{markets}[0]{submarkets}, 'have sub markets key');
is($result->{markets}[0]{submarkets}[0]{name}, '主要货币对', 'name  is translated');
is_deeply(
    $result->{markets}[0]{submarkets}[0]{symbols}[0],
    {
        'symbol' => 'frxEURCAD',
        'events' => [{
                'descrip' => 'Closes early (at 21:00)',
                'dates'   => 'Fridays'
            }
        ],
        'name'       => "abcd",
        'settlement' => '',
        'times'      => {
            'open'       => ['00:00:00'],
            'close'      => ['23:59:59'],
            'settlement' => '23:59:59'
        }
    },
    'a instance of symbol'
);

for my $m (@{$result->{markets}}){
  for my $subm (@{$m->{submarkets}}){
    for my $sym (@{$subm->{symbols}}){
      if($sym->{symbol} eq 'BSESENSEX30'){
        ok($sym->{feed_license}, 'have feed_license');
        ok($sym->{delay_amount}, 'have delay_amount');
      }

    }
  }
}

done_testing();

