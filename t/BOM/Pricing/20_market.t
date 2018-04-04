use strict;
use warnings;
use utf8;
use BOM::Test::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $c = BOM::Test::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);

my $method = 'trading_times';
subtest $method => sub {
    my $params = {
        language => 'EN',
        'args'   => {'trading_times' => '2016-03-16'}};
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    ok($result->{markets}[0]{submarkets}, 'have sub markets key');
    is($result->{markets}[0]{submarkets}[0]{name}, 'Major Pairs', 'name  is translated');
    is_deeply(
        $result->{markets}[0]{submarkets}[0]{symbols}[0],
        {
            'symbol' => 'frxAUDJPY',
            'events' => [{
                    'descrip' => 'Closes early (at 21:00)',
                    'dates'   => 'Fridays'
                }
            ],
            'name'  => "AUD/JPY",
            'times' => {
                'open'       => ['00:00:00'],
                'close'      => ['23:59:59'],
                'settlement' => '23:59:59'
            }
        },
        'a instance of symbol'
    );

    OUTER: for my $m (@{$result->{markets}}) {
        for my $subm (@{$m->{submarkets}}) {
            for my $sym (@{$subm->{symbols}}) {
                if ($sym->{symbol} eq 'BSESENSEX30') {
                    ok($sym->{feed_license}, 'have feed_license');
                    ok($sym->{delay_amount}, 'have delay_amount');
                    last OUTER;
                }

            }
        }
    }

};

$method = 'asset_index';

my $email  = 'test@binary.com';
my $client_mf = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
    broker_code => 'MF',
    email       => $email,
});
my ($token_mf) = BOM::Database::Model::OAuth->new->store_access_token_only(1, $client_mf->loginid);

my $entry_count_mlt = 7;
my @first_entry_mlt = [
              "R_10",
              "Volatility 10 Index",
              [
                [
                  "callput",
                  "Higher/Lower",
                  "5t",
                  "365d"
                ],
                [
                  "callput",
                  "Rise/Fall",
                  "5t",
                  "365d"
                ],
                [
                  "touchnotouch",
                  "Touch/No Touch",
                  "2m",
                  "365d"
                ],
                [
                  "endsinout",
                  "Ends Between/Ends Outside",
                  "2m",
                  "365d"
                ],
                [
                  "staysinout",
                  "Stays Between/Goes Outside",
                  "2m",
                  "365d"
                ],
                [
                  "digits",
                  "Digits",
                  "5t",
                  "10t"
                ],
                [
                  "asian",
                  "Asians",
                  "5t",
                  "10t"
                ]
              ]
            ];

subtest $method.' logged in - no arg' => sub {
    my $params = {
        language => 'EN',
        token    => $token_mf,
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Maltainvest (MF)

};

subtest $method.' logged in - with arg' => sub {
    my $params = {
        language => 'EN',
        token    => $token_mf,
        args     => {landing_company => 'malta'}
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Binary (Europe) Ltd
    # Only trades volatilities, so should be 7 entries and first entry should
    #   be R_10 with all contract categories except lookbacks.
    is(scalar(@$result), $entry_count_mlt, 'correct number of entries');
    is_deeply($result->[0], @first_entry_mlt, 'First entry matches expected');
};

subtest $method.' logged out - no arg' => sub {
    my $params = {
        language => 'EN',
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be CR
};

subtest $method.' logged out - with arg' => sub {
    my $params = {
        language => 'EN',
        args     => {landing_company => 'malta'}
    };
    my $result = $c->call_ok($method, $params)->has_no_system_error->has_no_error->result;
    # Result should be for Binary (Europe) Ltd
    # Only trades volatilities, so should be 7 entries and first entry should
    #   be R_10 with all contract categories except lookbacks.
    is(scalar(@$result), $entry_count_mlt, 'correct number of entries');
    is_deeply($result->[0], @first_entry_mlt, 'First entry matches expected');
};


done_testing();
