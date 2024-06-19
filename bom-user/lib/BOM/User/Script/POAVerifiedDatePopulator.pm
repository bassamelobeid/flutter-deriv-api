package BOM::User::Script::POAVerifiedDatePopulator;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::POAVerifiedDatePopulator - Adds the best POA verified date to the `users.poa_issuance` table.

=head1 SYNOPSIS

    BOM::User::Script::POAVerifiedDatePopulator::run;

=head1 DESCRIPTION

This module is used by the `poa_verified_date_populator.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run once to bring the verification date from the current database records.

=cut

use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use Date::Utility;
use JSON::MaybeXS qw(encode_json);
use BOM::User::Client::AuthenticationDocuments::Config;
use BOM::User::Script::POAIssuancePopulator;

=head2 run

Adds the best POA verified date to the `users.poa_issuance` table from users DB.

It takes a hashref argument:

=over

=item * C<noisy> - boolean to print some info as the script goes on

=back

Returns C<undef>

=cut

sub run {
    my @broker_codes = LandingCompany::Registry->all_real_broker_codes();

    my $poa_types          = BOM::User::Client::AuthenticationDocuments::Config::poa_types();
    my $user_db            = BOM::Database::UserDB::rose_db()->dbic;
    my $lifetime_valid_ids = {};
    my $binary_user_ids    = {};
    my $args               = shift // {};

    for my $broker_code (@broker_codes) {
        my $dbic = BOM::Database::ClientDB->new({
                broker_code => $broker_code,
            })->db->dbic;

        # we will move around in a paginated fashion
        my $limit         = $args->{limit} // 100;
        my $offset        = 0;
        my $verified_date = [];
        my $counter       = 0;

        do {
            printf("Retrieving POA verified_date with offset = %d, broker = %s\n", $offset, $broker_code) if $args->{noisy};

            # grab the best POA for each binary user id in the current broker code
            $verified_date = $dbic->run(
                fixup => sub {
                    $_->selectall_arrayref(
                        'select binary_user_id, verified_date, lifetime_valid from betonmarkets.get_poa_best_verified_date(?, ?, ?)',
                        {Slice => {}},
                        $poa_types, $limit, $offset
                    );
                });

            # carry the lifetime valids across broker codes
            $lifetime_valid_ids = +{$lifetime_valid_ids->%*, map { $_->{lifetime_valid} ? ($_->{binary_user_id} => 1) : () } $verified_date->@*};

            # we need to compare verified dates across broker codes
            # and discard any lifetime valid binary user id
            $binary_user_ids = BOM::User::Script::POAIssuancePopulator::get_best_date(
                $binary_user_ids,
                +{
                    map  { ($_->{binary_user_id} => Date::Utility->new($_->{verified_date})) }
                    grep { !$lifetime_valid_ids->{$_->{binary_user_id}} } $verified_date->@*
                });

            $offset  += $limit;
            $counter += scalar @$verified_date;
        } while (scalar @$verified_date);

        printf("Finished = %d users found with POA verified_date, broker = %s\n", $counter, $broker_code) if $args->{noisy};
    }

    # massive upsert
    $user_db->run(
        fixup => sub {
            $_->do('SET statement_timeout = 0; SELECT users.massive_poa_verified_date(?)', undef,
                encode_json(get_massive_arrayref($binary_user_ids)));
        });
}

=head2 get_massive_arrayref

It takes a hashref whose keys are binary user ids and values are verified dates.

Transform it into an arrayref of hashref with the following structure:

=over 4

=item C<binary_user_id> - the binary user id

=item C<verified_date> - the verified date

=back

Returns hashref.

=cut

sub get_massive_arrayref {
    my $hash = shift;

    return [map { +{binary_user_id => $_, verified_date => $hash->{$_}->date_yyyymmdd} } keys $hash->%*];
}

1;
