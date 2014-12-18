use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/lib";
use Test::More;
use APIHelper qw(request decode_json);

use BOM::Platform::Data::Persistence::ConnectionBuilder;
use BOM::Database::AutoGenerated::Rose::DoughflowAddressDiff::Manager;

my $loginid = 'CR0011';

my $connection_builder = BOM::Platform::Data::Persistence::ConnectionBuilder->new({
    client_loginid => $loginid,
    operation      => 'write',
});
BOM::Database::AutoGenerated::Rose::DoughflowAddressDiff::Manager->delete_doughflow_address_diff(
    where => [
        client_loginid => $loginid,
    ],
    db => $connection_builder->db
);

my $r = request(
    'GET',
    '/client/address_diff',
    {
        client_loginid => $loginid,
        currency_code  => 'USD'
    });
my $cli_data = decode_json($r->content);
is($cli_data->{loginid}, $loginid, 'correct client');
my @expected_fields = qw( address_state address_postcode address_city address_line_1 country address_line_2 );
isnt($cli_data->{$_}, undef, "property $_ is defined") foreach @expected_fields;

$r = request(
    'POST',
    '/client/address_diff',
    {
        client_loginid => $loginid,
        currency_code  => 'USD',
        street         => 'CHANGED-street'
    });
my $d = decode_json($r->content);
is $d->{diff}->{street}, 'CHANGED-street';

done_testing();
