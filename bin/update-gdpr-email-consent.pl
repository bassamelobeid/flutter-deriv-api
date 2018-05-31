#!/usr/bin/env perl
use strict;
use warnings;

=pod

This script performs a simple task: it marks all European users as *not* providing consent for email communication.

It will iterate through all users who might be considered European, and is intended as a one-off job to clear up
the database for the GDPR regulation starting in May 2018.

=cut

no indirect;

use Try::Tiny;
use Locale::Object::Continent;

use BOM::User;
use BOM::User::Client;
use BOM::Database::ClientDB;

use Log::Any qw($log);
use Log::Any::Adapter q{Stdout}, log_level => 'info';

# Total number changed
my $updated_user_count = 0;
# Per-user-id lookup - not strictly required, but we use this to avoid unnecessary updates
# when the same user ID has multiple client accounts, possibly distributed across multiple
# broker codes.
my %updated_user_id;

# GDPR regulations apply to European landing companies only. However, many of our European
# users have only a VR account, and those need to be considered as well. This technically
# also needs to cover ChampionFX users, since even if the CH accounts are closed the same
# user_id may later be used for a binary.com account - and if they're a European client,
# keeping the old status would be problematic.
#
# So, we'll start with a lookup table that can tell us whether a country is considered "in the EU" or not:
my %eu_country = do {
    my $eu = Locale::Object::Continent->new(name => "Europe");
    map { $_->code_alpha2 => 1 } $eu->countries
};

# ... and then go through all the broker codes that *might* have European users - effectively,
# everyone except for CR.
for my $broker (qw(MX MF MLT VRTC CH VRCH)) {
    # We don't have any strict requirements on data being recent here,
    # since we can rerun the script multiple times if needed.
    BOM::Database::ClientDB->new({
        broker_code => $broker,
        operation   => 'replica'
    })->db->dbic->run(
        fixup => sub {
            my $dbh = $_;
            # Bit of a hack, but we know that all our login IDs will sort lexically greater than the empty string.
            my $sth = $dbh->prepare(q{select loginid from betonmarkets.client where loginid > coalesce(?, '') order by loginid limit 100});

            my @login_ids;
            do {
                # Start from the last ID - this will be undef on first iteration anyway,
                # but we use an explicit `// undef` to prevent it from being used as an lvalue
                $sth->execute($login_ids[-1] // undef);
                @login_ids = map { $_->{loginid} } @{ $sth->fetchall_arrayref({}) };

                for my $login_id (@login_ids) {
                    try {
                        my $client = BOM::User::Client->new({ loginid => $login_id });
                        my $user_id = $client->binary_user_id or die 'no user ID for ' . $login_id;

                        # We only need to check each user_id once - we can ignore silently if we've already processed
                        return if $updated_user_id{$user_id}++;

                        # At this point, we have someone who is *either* in one of the European broker codes, or has a
                        # country/citizenship covered by the GDPR rules... or can be ignored. Please note that the
                        # broker-code check here is *not* good practice for real code, we can only get away with it in
                        # a throwaway script like this one. Also note that we want to be as inclusive as possible here:
                        # not sending someone a marketing email is considered "harmless" compared to exposing us to
                        # liability for GDPR violations, so let's check all the country information we can.
                        my $european_country = (
                            $broker =~ /^M/
                                or
                            grep {
                                $_ and exists $eu_country{lc $_}
                            } $client->residence,
                              $client->tax_residence,
                              $client->citizen,
                              $client->place_of_birth
                        );

                        # Sample users manually checked in QA, but if we want to verify things in production this might help
                        # build confidence that our filtering is correct.
                        $log->debugf('Client [%s] has broker %s, residence %s, tax_residence %s, citizen %s, place of birth %s',
                            $login_id,
                            $broker,
                            map $client->$_, qw(residence tax_residence citizen place_of_birth)
                        );

                        my $user = $client->user or do {
                            $log->errorf('Failed to instantiate user for client [%s], binary_user_id was %d, skipping', $login_id, $user_id);
                            return;
                        };
                        if(not $european_country) {
                            $log->infof('Seems that user [%s] for client account [%s] has no European links, skipping', $user_id, $login_id);
                        } elsif($user->email_consent) {
                            $log->infof('Clearing consented status for user [%s] due to client account [%s]', $user_id, $login_id);
                            $user->email_consent(0);
                            $user->save;
                            ++$updated_user_count;
                        } else {
                            $log->infof('No previous consent from user [%s] for client account [%s], ignoring', $user_id, $login_id);
                        }
                    } catch {
                        $log->errorf('Unexpected exception while processing client account [%s] - %s', $login_id, $_);
                    }
                }
            } while @login_ids;
        }
    );
}

$log->infof('Update complete, %d user(s) were checked, %d updated', 0 + keys %updated_user_id, $updated_user_count);
