#!/etc/rmg/bin/perl

use strict;
use warnings;

use Test::More (tests => 37);
use Test::Exception;
use Test::Warnings;

use BOM::Database::ClientDB;

use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

my $init_info = {
    broker_code => 'CR',
};

my $connection_builder;

Test::More::ok($connection_builder = BOM::Database::ClientDB->new($init_info), 'Create new ConnectionBuilder object');

Test::More::isa_ok($connection_builder, 'BOM::Database::ClientDB');

my $db;
Test::More::ok($db = $connection_builder->db, 'Get db object');

Test::More::isa_ok($db, 'BOM::Database::Rose::DB');

delete $init_info->{broker_code};
delete $init_info->{client_loginid};

throws_ok { $connection_builder = BOM::Database::ClientDB->new($init_info); }
qr/At least one of broker_code, or client_loginid must be specified/,
    'Dies when none of company_name, broker, and client_loginid are passed to ConnectionBuilder constructor';

foreach my $client_loginid (qw( VRTC1234 CR1234 MLT1234 MX1234 )) {
    $init_info->{client_loginid} = $client_loginid;
    Test::More::ok($connection_builder = BOM::Database::ClientDB->new($init_info),
        'Create new ConnectionBuilder object using client_loginid(' . $client_loginid . ')');
    Test::More::ok($db = $connection_builder->db, 'Get db object');
}

delete $init_info->{client_loginid};
foreach my $broker_code (qw( VRTC CR MX MLT )) {
    $init_info->{broker_code} = $broker_code;
    Test::More::ok(
        $connection_builder = BOM::Database::ClientDB->new($init_info),
        'Create new ConnectionBuilder object using broker_code(' . $broker_code . ')'
    );
    Test::More::ok($db = $connection_builder->db, 'Get db object');
}

$init_info->{broker_code} = 'VRTT';    # There is no such broker
throws_ok { $connection_builder = BOM::Database::ClientDB->new($init_info); $db = $connection_builder->db; }
qr/No such domain with the broker code VRTT/, 'Dies when invalid broker code is passed to ConnectionBuilder constructor';

delete $init_info->{broker_code};
$init_info->{client_loginid} = 'VRTT1234';    # No such broker or loginid
throws_ok { $connection_builder = BOM::Database::ClientDB->new($init_info); $db = $connection_builder->db; }
qr/No such domain with the broker code VRTT/, 'Dies when invalid client loginid is passed to ConnectionBuilder constructor';

$init_info = {
    company_name => 'Binary Ltd',
    broker_code  => 'FOG',
    operation    => 'shooshtari',
};

throws_ok { $connection_builder = BOM::Database::ClientDB->new($init_info); $connection_builder->db; }
qr/Invalid operation for DB/, 'Successfully caught invalid init params, operation [' . $init_info->{'operation'} . ']';

$init_info = {
    broker_code => 'FOG',
};

Test::More::ok($connection_builder = BOM::Database::ClientDB->new($init_info), 'Create connection_builder');
$db = $connection_builder->db;
Test::More::isa_ok($db, 'BOM::Database::Rose::DB');

foreach my $op (qw( write collector replica backoffice_replica )) {
    $init_info = {
        broker_code => 'FOG',
        operation   => $op,
    };
    ok($connection_builder = BOM::Database::ClientDB->new($init_info), "Create connection with explicit $op operation");
    $db = $connection_builder->db;
    isa_ok($db, 'BOM::Database::Rose::DB');
}

foreach my $serv_op (qw( write )) {
    $init_info = {
        broker_code => 'FOG',
        operation   => $serv_op,
    };
    ok($connection_builder = BOM::Database::ClientDB->new($init_info), "Create connection with explicit server for $serv_op operation");
    $db = $connection_builder->db;
    isa_ok($db, 'BOM::Database::Rose::DB');
}
