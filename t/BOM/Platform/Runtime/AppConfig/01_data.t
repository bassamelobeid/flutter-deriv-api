use Test::Most 0.22 (tests => 22);
use Test::Warnings;
use Data::Hash::DotNotation;
use Sys::Hostname qw(hostname);

my $hash = {
    name  => 'P-Body',
    parts => {
        hand     => 'rxi332.22',
        camera   => 'ds10',
        versions => ['12', '10', '14'],
    }};
my $data = Data::Hash::DotNotation->new(data => $hash);

is $data->get('name'),         'P-Body';
is $data->get('parts.hand'),   'rxi332.22';
is $data->get('parts.camera'), 'ds10';
is $data->get('parts.versions')->[0], '12';

ok $data->set('name', 'Trent');
is $data->get('name'), 'Trent';

ok $data->set('parts.camera', 'ds12');
is $data->get('parts.camera'), 'ds12';
ok !$data->get('parts.hand.left');

ok $data->key_exists('name');
ok $data->key_exists('parts.hand');
ok $data->key_exists('parts.camera');
ok !$data->key_exists('parts.material');
ok !$data->key_exists('parts.hand.left');
ok !$data->key_exists('type');

$hash = {
    empty => '',
    count => 10,
};
$data = Data::Hash::DotNotation->new(data => $hash);
ok $data->get('count'), 'Count is availabled in root';
ok !$data->key_exists('users.signups.count'), 'count is not found under users.signups';
ok !$data->get('users.signups.count'),        'root_var is not defined under users.signups';

ok $data->set('users.signups.count', 20), "Now set";
ok $data->key_exists('users.signups.count'), 'Now count should be found in users.signups';
is $data->get('users.signups.count'), 20, 'count is 20';
