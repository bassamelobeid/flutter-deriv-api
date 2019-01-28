use strict;
use warnings;

use BOM::Database::UserDB;
use BOM::User;
use BOM::MT5::User::Async;
use BOM::Config::RedisReplicated;

use Date::Utility;
use JSON::MaybeUTF8 qw/decode_json_utf8 encode_json_utf8/;

my $user_dbic = BOM::Database::UserDB::rose_db()->dbic;

use constant REDIS_MASTERKEY =>'MT5_REMINDER_AUTHENTICATION_CHECK';
my $redis = BOM::Config::RedisReplicated::redis_write;

# Fetch binary_user_ids from MT5 accounts created in the last 5 days
# The query fetches the binary_user_id and aggregates the associated mt5 loginids and creation stamp in json format in an array
my $binary_users = $user_dbic->run(
    fixup => sub {
        $_->selectall_arrayref("SELECT 
            binary_user_id, array_agg(json_build_object('mt5_loginid', loginid, 'creation_stamp', creation_stamp::date)) AS mt5_details
            FROM users.loginid
            where creation_stamp::date >= (now()::date - 5)
            and loginid like 'MT%'
            GROUP BY binary_user_id;", { Slice => {} });
    });

foreach my $user_details (@$binary_users) {

    my $binary_user_id = $user_details->{binary_user_id};
    my $user = BOM::User->new(id => $binary_user_id);
    
    # real\vanuatu is only for CR
    my @clients = $user->clients_for_landing_company('costarica');
    
    # Skip if client is fully authenticated
    next if $clients[0]->fully_authenticated;
    
    # Check the MT5 group type
    foreach my $json_data (@{$user_details->{mt5_details}}) {
        my $mt5_details_ref = decode_json_utf8($json_data);
        my $mt5_loginid = $mt5_details_ref->{mt5_loginid};
        
        $mt5_loginid =~ s/\D//g;
        
        my $result = BOM::MT5::User::Async::get_user($mt5_loginid)->get;
        
        next unless $result->{group} =~ /^real\\(vanuatu|labuan)/;
        
        # Store in redis with the current time (Convert the time to epoch for consistency)
        my $creation_mt5_epoch = Date::Utility->new($mt5_details_ref->{creation_stamp})->epoch;
        
        my $data = encode_json_utf8({
            creation_epoch => $creation_mt5_epoch,
            has_email_sent => 0
        });
        
        $redis->hsetnx(REDIS_MASTERKEY, $binary_user_id, $data);
        
        # We only need to evaluate only ONE real account
        last;
        
    }
}
