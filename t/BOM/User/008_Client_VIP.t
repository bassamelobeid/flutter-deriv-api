use strict;
use warnings;

use Test::MockTime;
use Test::More qw(no_plan);
use Test::Exception;
use Date::Utility;
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

use User::Client;

my $login_id = 'CR0011';
my $client;

lives_ok { $client = User::Client::get_instance({'loginid' => $login_id}); }
"Can create client object 'User::Client::get_instance({'loginid' => $login_id})'";

is($client->is_vip,    0,     "client is not VIP");
is($client->vip_since, undef, "client vip_since is undef");

my $now = Date::Utility->new;
lives_ok { $client->is_vip(1); } "turning client vip works";

is($client->is_vip, 1, "client is VIP");
{
    my $vip_since = Date::Utility->new($client->vip_since);
    ok($vip_since->is_same_as($now) or $vip_since->is_after($now), "client vip_since has sane value");
}

# make sure we don't update the vip_since when setting is_vip() multiple times
my $initial_vip_since = $client->vip_since;
lives_ok { $client->is_vip(1); } "trying to turn it on while it's on doesn't crash";
is($client->vip_since, $initial_vip_since, "client vip_since doesn't change if you try to set_vip(1) again");

lives_ok { $client->save() } "can save client";

# reload client
lives_ok { $client = User::Client::get_instance({'loginid' => $login_id}); }
"Can create client object 'User::Client::get_instance({'loginid' => $login_id})'";

is($client->is_vip, 1, "saving VIP status work, flag persist reloads.");
is($client->vip_since, $initial_vip_since, "client vip_since value persist reloads (got: " . $client->vip_since . ")");

lives_ok { $client->is_vip(0) } "setting is_vip to 0";
is($client->vip_since, undef, "client vip_since reset to undef when toogling off VIP status");
lives_ok { $client->save() } "can save client";

# reload client
lives_ok { $client = User::Client::get_instance({'loginid' => $login_id}); }
"Can create client object 'User::Client::get_instance({'loginid' => $login_id})'";

is($client->is_vip,    0,     "saving non-VIP status work, flag persist reloads.");
is($client->vip_since, undef, "client vip_since reset persist reloads");

