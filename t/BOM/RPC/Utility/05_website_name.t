use strict;
use warnings;

use Test::Most;
use Test::MockModule;

use Data::Dumper;
use Date::Utility;

use BOM::Test::Data::Utility::UnitTestDatabase;
use BOM::RPC::v3::Utility;
use BOM::Config;
use Test::MockModule;

use utf8;

my $mock_bom_config = Test::MockModule->new('BOM::Config');
$mock_bom_config->mock(
    'qa_config',
    sub {
        return {
            nodes => {
                'qa91.regentmarkets.com' => {
                    'mac_address' => 'ea:26:3f:46:60:44',
                    'type'        => 'm1.xlarge',
                    'ip'          => '192.168.13.44',
                    'website'     => 'qa91.deriv.dev',
                    'region'      => 'qa-cj',
                    'vpc_ip'      => '172.16.2.44',
                    'env'         => 'qa91',
                    'provider'    => 'OpenStack'
                },
                'qa20.regentmarkets.com' => {
                    'region'   => 'ap-southeast-1',
                    'iam_role' => 'qa_deploy',
                    'vpc_ip'   => '172.30.0.224',
                    'env'      => 'qa03',
                    'provider' => 'Amazon EC2',
                    'type'     => 'm5.xlarge',
                    'ip'       => '52.221.152.164',
                    'pool'     => 'qa',
                    'website'  => 'binaryqa20.com'
                },
            }};
    });

my $server_name = 'qa20';
is BOM::RPC::v3::Utility::website_name($server_name), 'binaryqa20.com', 'Correct website_name returned for aws QA';
$server_name = 'qa91';
is BOM::RPC::v3::Utility::website_name($server_name), 'qa91.deriv.dev', 'Correct website_name returned for openstack QA';

$server_name = 'anynotexistqaserver';
is BOM::RPC::v3::Utility::website_name($server_name), 'Deriv.com', 'Correct website_name returned for production';

done_testing();
