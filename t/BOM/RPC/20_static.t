use strict;
use warnings;

use utf8;
use Test::BOM::RPC::Client;
use Test::Most;
use Test::Mojo;
use Data::Dumper;

my $c = Test::BOM::RPC::Client->new(ua => Test::Mojo->new('BOM::RPC')->app->ua);
subtest 'residence_list' => sub {
    my $result = $c->call_ok('residence_list', {language => 'ZH_CN'})->has_no_system_error->result;
    my ($cn) = grep { $_->{value} eq 'cn' } @$result;
    is_deeply(
        $cn,
        {
            'value'     => 'cn',
            'text'      => "中国",
            'phone_idd' => '86'
        },
        'cn is correct'
    );
};

subtest 'states_list' => sub {
    my $result = $c->call_ok(
        'states_list',
        {
            language => 'ZH_CN',
            args     => {states_list => 'cn'}})->has_no_system_error->result;
    my ($cn) = grep { $_->{value} eq 'cn' } @$result;
    is_deeply(
        $cn,
        {
            'value'     => 'cn',
            'text'      => "中国",
            'phone_idd' => '86'
        },
        'cn is correct'
    );
};

done_testing();
