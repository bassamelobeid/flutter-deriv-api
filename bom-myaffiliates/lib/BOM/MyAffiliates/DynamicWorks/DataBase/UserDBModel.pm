package BOM::MyAffiliates::DynamicWorks::DataBase::UserDBModel;
use Object::Pad;

=head1 NAME

UserDB - A Perl class for interacting with the User database to store partner related data.

=head1 SYNOPSIS

    my $db = BOM::MyAffiliates::DynamicWorks::Database::CommisionDB->new();

    my $response = $db->getPartnerData($partner_id);

=head1 DESCRIPTION

This module provides a modern and simple interface for interacting with the User database 

=cut

use strict;
use warnings;

use BOM::Database::UserDB;
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;

class BOM::MyAffiliates::DynamicWorks::DataBase::UserDBModel {

    field $user_db;
    field $version = '1';    # Default version value

    BUILD {
        $user_db = BOM::Database::UserDB::rose_db(operation => 'replica');
    }

=head1 METHODS

=head2 new

This method initializes the class with the configuration for the User database.

=cut

=head2 get_mt5_affiliate_accounts_by_binary_user_ids

This method retrieves the MT5 affiliate accounts associated with the given binary user IDs.

=over 4

=item * Arguments

=over 4

=item - binary_user_ids: An array reference containing the binary user IDs of the affiliates.

=back

=item * Returns

A hash reference containing either an error message or the MT5 affiliate accounts.

=back

=cut

    method get_mt5_affiliate_accounts_by_binary_user_ids ($binary_user_ids) {
        try {
            my $output = $user_db->dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        qq{
                            select * from mt5.get_mt5_affiliate_accounts(?, ?)
                        }
                    );
                    $sth->execute($binary_user_ids, ['main']);
                    my $result = $sth->fetchall_arrayref({});
                    return $result;
                });

            return {
                mt5_affiliate_accounts => $output,
                success                => 1
            }
        } catch ($e) {
            return {
                error   => "Error getting mt5 affiliate accounts: $e",
                success => 0
            };
        }
    }
}

1;

