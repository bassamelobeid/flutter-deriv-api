package BOM::User::Script::POIExpirationPopulator;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::POIExpirationPopulator - Adds the best POI expiration date to the `users.poi_expiration` table.

=head1 SYNOPSIS

    BOM::User::Script::POIExpirationPopulator::run;

=head1 DESCRIPTION

This module is used by the `poi_expiration_populator.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run once to bring the expiration date from the current database records.

=cut

use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use Date::Utility;
use JSON::MaybeXS qw(encode_json);
use BOM::User::Client::AuthenticationDocuments::Config;

=head2 run

Adds the best POI expiration date to the `users.poi_expiration` table from users DB.

It takes a hashref argument:

=over

=item * C<noisy> - boolean to print some info as the script goes on

=back

Returns C<undef>

=cut

sub run {
    my @broker_codes = qw/CR MF/;

    my $poi_types          = BOM::User::Client::AuthenticationDocuments::Config::poi_types();
    my $user_db            = BOM::Database::UserDB::rose_db()->dbic;
    my $lifetime_valid_ids = {};
    my $binary_user_ids    = {};
    my $args               = shift // {};

    for my $broker_code (@broker_codes) {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code => $broker_code,
            })->db->dbic;

        # we will move around in a paginated fashion
        my $limit       = $args->{limit} // 100;
        my $offset      = 0;
        my $expirations = [];
        my $counter     = 0;

        do {
            printf("Retrieving POI expiration with offset = %d, broker = %s\n", $offset, $broker_code) if $args->{noisy};

            # grab the best POI for each binary user id in the current broker code
            $expirations = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref(
                        'select binary_user_id, expiration_date, lifetime_valid from betonmarkets.get_poi_best_expiration_date(?, ?, ?)',
                        {Slice => {}},
                        $poi_types, $limit, $offset
                    );
                });

            # carry the lifetime valids across broker codes
            $lifetime_valid_ids = +{$lifetime_valid_ids->%*, map { $_->{lifetime_valid} ? ($_->{binary_user_id} => 1) : () } $expirations->@*};

            # we need to compare expirations dates across broker codes
            # and discard any lifetime valid binary user id
            $binary_user_ids = get_best_date(
                $binary_user_ids,
                +{
                    map { ($_->{binary_user_id} => Date::Utility->new($_->{expiration_date})) }
                        grep {
                        eval { Date::Utility->new($_->{expiration_date}) }
                        }
                        grep { !$lifetime_valid_ids->{$_->{binary_user_id}} } $expirations->@*
                });

            $offset  += $limit;
            $counter += scalar @$expirations;
        } while (scalar @$expirations);

        printf("Finished = %d users found with POI expiration, broker = %s\n", $counter, $broker_code) if $args->{noisy};
    }

    # massive upsert with statement timeout = 0 as this might take some time
    $user_db->run(
        fixup => sub {
            $_->do('SET statement_timeout = 0; SELECT users.massive_poi_expiration(?)', undef, encode_json(get_massive_arrayref($binary_user_ids)));
        });
}

=head2 get_massive_arrayref

It takes a hashref whose keys are binary user ids and values are expiration dates.

Transform it into an arrayref of hashref with the following structure:

=over 4

=item C<binary_user_id> - the binary user id

=item C<expiration_date> - the expiration date

=back

Returns hashref.

=cut

sub get_massive_arrayref {
    my $hash = shift;

    return [map { +{binary_user_id => $_, expiration_date => $hash->{$_}->date_yyyymmdd} } keys $hash->%*];
}

=head2 get_best_date

It takes a hashref of expirations dates indexed by binary user id and a new
hashref with the same structure.

Will return a new hashref with the best dates from both hashrefs for each
binary user id.

=cut

sub get_best_date {
    my ($hash1, $hash2) = @_;

    return +{
        $hash2->%*,
        $hash1->%*,
        map {
            # override only if the expiration date is better (future)
            $hash2->{$_}->is_after($hash1->{$_} // $hash2->{$_}) ? ($_ => $hash2->{$_}) : ();
        } keys $hash2->%*
    };
}

1;
