#!/usr/bin/perl

use strict;
use warnings;

use BOM::Config::RedisReplicated;
use BOM::Database::Model::AccessToken;
use Date::Utility;

my $db_model   = BOM::Database::Model::AccessToken->new;
my $redis_read = BOM::Config::RedisReplicated::redis_auth_write();

foreach my $key (@{$redis_read->keys("TOKEN::*")}) {
    my (undef, $token) = split '::', $key;
    my $last_used = $redis_read->hget($key, 'last_used');
    $db_model->update_token_last_used($token, $last_used) if $last_used;
}
