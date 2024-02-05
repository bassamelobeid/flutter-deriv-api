package BOM::User::Script::POIOwnershipPopulator;

use strict;
use warnings;
no indirect;

=head1 NAME

BOM::User::Script::POIOwnershipPopulator - Claims ownership for existing documents

=head1 SYNOPSIS

    BOM::User::Script::POIOwnershipPopulator::run;

=head1 DESCRIPTION

This module is used by the `poi_ownership_populator.pl` script. Meant to provide a testable
collection of subroutines.

Meant to be run once to backpopulate ownership of uploaded documents.

=cut

use BOM::Database::ClientDB;
use BOM::Database::UserDB;
use Date::Utility;
use JSON::MaybeXS qw(encode_json);
use BOM::User::Client::AuthenticationDocuments::Config;

use constant DEFAULT_LIMIT => 100;

=head2 run

Runs through all the client databases, looking for POI having:

=over 4

=item * C<issuing_country>

=item * C<document_type>

=item * C<document_id>

=back

It takes a hashref argument:

=over

=item * C<noisy> - boolean to print some info as the script goes on

=back

Returns C<undef>

=cut

sub run {
    my @broker_codes = LandingCompany::Registry->all_real_broker_codes();

    my $poi_types = BOM::User::Client::AuthenticationDocuments::Config::poi_types();
    my $args      = shift // {};

    for my $broker_code (@broker_codes) {
        # we will move around in a paginated fashion
        my $limit     = $args->{limit} // DEFAULT_LIMIT;
        my $last_id   = 0;
        my $documents = [];
        my $counter   = 0;
        my $next_id;
        print $limit . "\n";
        do {
            printf("Retrieving POI ownable documents with id > 0, broker = %s\n", $last_id, $broker_code) if $args->{noisy};

            # grab the documents that can be backpopulated
            $documents = ownable_documents($broker_code, $poi_types, $limit, $last_id);

            my $page_size = scalar @$documents;

            $counter += $page_size;

            my ($first) = reverse $documents->@*;

            if ($first) {
                # massive upsert
                apply_ownership($documents);

                $next_id = $first->{id} if $first->{id} && $first->{id} > $last_id;

                $last_id = $next_id;
            }

            $next_id = undef if $page_size < $limit;
        } while ($next_id);

        printf("Finished = %d documents found with complete POI data, broker = %s\n", $counter, $broker_code) if $args->{noisy};
    }

    return undef;
}

=head2 apply_ownership

Massive insert the given documents into the POI owenserhip table at userdb. 

Note: by moving on a paginated ascendent fashion, we ensure the older the ownership the higher the priority as a desired side effect.

It takes an arrayref of hashrefs, containing:

=over 4 

=item * C<binary_user_id> - the owner of the document

=item * C<document_type> - self explanatory

=item * C<document_id> - might be a bit confusing (that's how the db column is named), this is the actual document number

=item * C<issuing_country> - self explanatory

=back

Returns C<undef>

=cut

sub apply_ownership {
    my ($documents) = @_;

    my $user_db = BOM::Database::UserDB::rose_db()->dbic;

    $user_db->run(
        fixup => sub {
            $_->do('SET statement_timeout = 0; SELECT users.massive_poi_ownership(?)', undef, encode_json($documents));
        });

    return undef;
}

=head2 ownable_documents

Hits the database looking for ownable documents on a paginated fashion, it takes:

=over 4

=item * C<$broker_code> - db to target

=item * C<$poi_types> - an arrayref of POI document types

=item * C<$limit> - limit for the query

=item * C<$last_id> - and id to use as pivot for the query

=back

Returns an arrayref of hasrefs, containing:

=over 4

=item * C<id> - id of the document

=item * C<binary_user_id> - the owner of the document

=item * C<document_type> - self explanatory

=item * C<document_id> - might be a bit confusing (that's how the db column is named), this is the actual document number

=item * C<issuing_country> - self explanatory

=back

=cut

sub ownable_documents {
    my ($broker_code, $poi_types, $limit, $last_id) = @_;

    my $dbic = BOM::Database::ClientDB->new({
            broker_code => $broker_code,
            operation   => 'replica'
        })->db->dbic;

    return $dbic->run(
        fixup => sub {
            $_->selectall_arrayref(
                'select id, binary_user_id, document_type, issuing_country, document_id from betonmarkets.get_ownable_documents(?, ?, ?)',
                {Slice => {}},
                $poi_types, $limit, $last_id
            );
        });
}

1;
