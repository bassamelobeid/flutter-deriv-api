#!/usr/bin/env perl 

# This script is to sync MT5 Users information
# with the information we have in Binary.com ClientDB
# it syncs each MT5 group independently with the given broker code ClientDB
# you can always start from a specific MT5 Login id
# it also logs logins that we couldn't find in our DBs

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
Getopt::Long::Configure qw(gnu_getopt);

use Locale::Country::Extra;
use Array::Utils qw(array_minus);

use BOM::MT5::User::Async;
use BOM::Database::UserDB;
use BOM::Database::ClientDB;
use BOM::MT5::User::Async;

my $group       = '';
my $broker_code = '';
my $skip        = 0;

# parse command line options
GetOptions(
    'mt_group|g=s'    => \$group,
    'broker_code|b=s' => \$broker_code,
    'start_from|s=i'  => \$skip,
) or die 'Usage $0 --mt_group --broker_code [--start_from]';

die 'MT5 group name is required' unless $group;
die 'DB broker code is required' unless $broker_code;

my $user_dbic = BOM::Database::UserDB::rose_db()->dbic;

my $client_dbic = BOM::Database::ClientDB->new({
        broker_code => $broker_code,
        operation   => 'replica'
    })->db->dbic;

print "Getting users under group $group\n";

my $group_future = BOM::MT5::User::Async::get_users_logins($group)->then(
    sub {
        my $logins = shift;
        print "$group got " . @$logins . " Clients\n";

        my $mt_logins = [];
        foreach (@$logins) {
            next unless $_ >= $skip;
            push @$mt_logins, "MT$_";
        }
        print "Trying to process " . @$mt_logins . " MT5 logins\n";

        my $binary_users = $user_dbic->run(
            fixup => sub {
                $_->selectall_hashref('SELECT loginid, binary_user_id FROM users.loginid WHERE loginid = ANY(?);', 'binary_user_id', {}, $mt_logins);
            });

        my $binary_users_ids = [keys %$binary_users];

        if (@$binary_users_ids == 0) {
            print "no users found in UsersDB for group $group\n";
            exit 1;
        }

        my $clients = $client_dbic->run(
            fixup => sub {
                $_->selectall_hashref(
                    "SELECT
            binary_user_id,
            MAX(first_name) as first_name,
            MAX(last_name) as last_name,
            MAX(residence) as residence,
            MAX(email) as email,
            MAX(address_line_1) as address,
            MAX(phone) as phone_number,
            MAX(address_state) as state,
            MAX(address_city) as city,
            MAX(address_postcode) as zipcode
            FROM betonmarkets.client
            WHERE binary_user_id = ANY(?) 
            GROUP BY binary_user_id;", 'binary_user_id', {}, $binary_users_ids
                );
            });

        if (keys %$clients == 0) {
            print "no clients found in $broker_code ClientDB for group $group\n";
            exit 1;
        }
        my @update_operations;
        my @found_logins;
        foreach my $client (values %$clients) {
            my $login = do { $binary_users->{$client->{binary_user_id}}->{loginid} =~ /MT(\d+)/; $1 };
            push @found_logins, "MT$login";

            my $update_future = BOM::MT5::User::Async::update_user({
                    login   => $login,
                    name    => $client->{first_name} . ' ' . $client->{last_name},
                    email   => $client->{email},
                    address => $client->{address},
                    phone   => $client->{phone_number},
                    state   => $client->{state},
                    city    => $client->{city},
                    zipCode => $client->{zipcode},
                    country => Locale::Country::Extra->new()->country_from_code($client->{residence}),
                }
                )->then(
                sub {
                    my $result = shift;
                    return Future->fail($result->{error}) if $result->{error};
                    print "Login $login has been updated\n";
                    return Future->done();
                });
            push @update_operations, $update_future;
        }

        #log logins with no match on our DB
        warn "$_ not found in $broker_code ClientDB\n" for array_minus(@$mt_logins, @found_logins);
        return Future->needs_all(@update_operations);
    });

$group_future->get();

print "Processing is done for group $group using $broker_code DB\n";
