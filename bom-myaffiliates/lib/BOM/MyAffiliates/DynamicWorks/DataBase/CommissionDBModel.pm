package BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel;
use Object::Pad;

=head1 NAME

CommissionDB - A Perl class for interacting with the Commission database to store partner related data.

=head1 SYNOPSIS

    my $db = BOM::MyAffiliates::DynamicWorks::Database::CommissionDBModel->new();

    my $response = $db->getPartnerData($partner_id);

=head1 DESCRIPTION

This module provides a modern and simple interface for interacting with the Commission database 

=cut

use strict;
use warnings;
use Syntax::Keyword::Try;

use BOM::Database::CommissionDB;
use JSON::MaybeUTF8 qw(:v1);
use Syntax::Keyword::Try;
use Log::Any qw($log);

class BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel {

    field $commission_db;
    field $version = '1';    # Default version value

    BUILD {
        $commission_db = BOM::Database::CommissionDB::rose_db();
    }

=head1 METHODS

=head2 new

This method initializes the class with the configuration for the Commission database.

=cut

=head2 add_new_affiliate

This method adds a new affiliate to the Commission database.

    method add_new_affiliate ($args) {

=over 4

=item * Arguments

The method expects a hash reference containing the following keys:

=over 4

=item - binary_user_id: The binary user ID of the affiliate.

=item - provider: The provider of the affiliate.

=item - payment_loginid: The payment login ID of the affiliate.

=item - affiliate_id: The ID of the affiliate.

=item - currency: The currency used by the affiliate.

=back

=item * Returns

A hash reference containing either an error message or the newly added affiliate ID.

=back

=cut

    method add_new_affiliate ($args) {

        for my $value (qw(binary_user_id external_affiliate_id payment_loginid payment_currency provider)) {
            return {
                error   => "$value is required",
                success => 0
            } unless $args->{$value};
        }
        try {
            my $id = $commission_db->dbic->run(
                ping => sub {
                    $_->do(
                        q{select * from affiliate.add_new_affiliate(?,?,?,?,?)},
                        undef,
                        $args->{binary_user_id},
                        $args->{external_affiliate_id},
                        $args->{payment_loginid},
                        $args->{payment_currency},
                        $args->{provider});
                });

            return {
                affiliate_id => $id,
                success      => 1
            };
        } catch {
            return {
                error  => "Error adding new affiliate: $_",
                sucess => 0
            };
        }
    }

=head2 add_new_affiliate_client

This method adds a new affiliate client to the Commission database.

    method add_new_affiliate_client ($args) {

=over 4

=item * Arguments

The method expects a hash reference containing the following keys:

=over 4

=item - affiliate_id: The ID of the affiliate.

=item - client_id: The ID of the client.

=back

=item * Returns

A hash reference containing either an error message or a success flag.

=back

=cut

    method add_new_affiliate_client ($args) {
        my $affiliate_client_id;
        for my $value (qw(affiliate_id client_loginid binary_user_id provider)) {
            return {
                error   => "$value is required",
                success => 0
            } unless $args->{$value};
        }
        try {
            $affiliate_client_id = $commission_db->dbic->run(
                ping => sub {
                    $_->do(
                        'SELECT * FROM affiliate.add_new_affiliate_client(?,?,?,?)',
                        undef,             $args->{client_loginid},
                        $args->{provider}, $args->{binary_user_id},
                        $args->{affiliate_id});
                });
        } catch ($e) {
            return {
                error   => "Error adding new affiliate client: $e",
                success => 0
            };
        }

        return {
            success             => 1,
            affiliate_client_id => $affiliate_client_id
        };
    }

=head2 add_pending_affiliate_client

This method adds a pending affiliate client to the Commission database.

    method add_pending_affiliate_client ($args) {

=over 4

=item * Arguments

The method expects a hash reference containing the following keys:

=over 4

=item - provider: The provider of the affiliate client.

=item - client_loginid: The login ID of the affiliate client.

=back

=item * Returns

A hash reference containing either an error message or a success flag.

=back

=cut

    method add_pending_affiliate_client ($args) {

        for my $value (qw(provider client_loginid binary_user_id)) {
            return {
                error   => "$value is required",
                success => 0
            } unless $args->{$value};
        }
        try {
            $commission_db->dbic->run(
                ping => sub {
                    $_->do(
                        'SELECT * FROM affiliate.add_pending_affiliate_client(?, ?, ?)',
                        undef,
                        $args->{client_loginid},
                        $args->{binary_user_id},
                        $args->{provider});
                });
        } catch {
            return {
                error   => "Error adding pending affiliate client: $_",
                success => 0
            };
        }

        return {success => 1};
    }

=head2 get_affiliates

This method retrieves affiliates associated with the given payment login ID.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - payment_loginid: The payment login ID of the affiliate.

=item - provider: The provider of the affiliate.

=item - binary_user_id: The binary user ID of the affiliate.

=item - external_affiliate_id: The external affiliate ID of the affiliate.

=back

=item * Returns

A hash reference containing either an error message or the list of affiliates.
In the below format:

    {
        affiliates => [
            {
            ...
            }
        ],
        success => 1
    }

=back

=cut

    method get_affiliates ($args) {
        try {
            my $output = $commission_db->dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        qq{
                                SELECT * FROM affiliate.get_affiliates(?, ?, ?, ?)
                            }
                    );
                    $sth->execute(($args->{payment_loginid}, $args->{provider}, $args->{binary_user_id}, $args->{external_affiliate_id}));
                    my $result = $sth->fetchall_arrayref({});
                    return $result;
                });
            return {
                affiliates => $output,
                success    => 1
            };
        } catch ($e) {
            return {
                error   => "Error getting affiliates: $e",
                success => 0
            };
        }

    }

=head2 upsert_affiliate_client_with_mapping

This method upserts an affiliate client with mapping to the Commission database.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - affiliate_client_id: The ID of the affiliate client.

=item - platform: The platform of the affiliate client.

=item - binary_user_id: The binary user ID of the affiliate client.

=item - affiliate_id: The ID of the affiliate.

=item - user_external_id: The external ID of the user.

=item - provider: The provider of the affiliate client.

=item - client_loginid_external_id: The external ID of the client login ID.

=back

=item * Returns

A hash reference containing either an error message or a success flag.

=back

=cut

    method upsert_affiliate_client_with_mapping ($args) {

        for my $value (qw(affiliate_client_id platform binary_user_id affiliate_id user_external_id provider client_loginid_external_id)) {
            return {
                error   => "$value is required",
                success => 0
            } unless $args->{$value};
        }

        try {
            my $output = $commission_db->dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        qq{
                                SELECT * FROM affiliate.upsert_affiliate_client_with_mapping(?, ?, ?, ?, ?, ?, ?)
                            }
                    );
                    $sth->execute(
                        $args->{affiliate_client_id},
                        $args->{platform},     $args->{binary_user_id},
                        $args->{affiliate_id}, $args->{user_external_id},
                        $args->{provider},     $args->{client_loginid_external_id});
                    my $result = $sth->fetchall_arrayref({});
                    return $result;
                });
            return {
                success => 1,
                output  => $output
            };
        } catch ($e) {
            return {
                error   => "Error upserting affiliate client mapping: $e",
                success => 0
            };
        }
    }

=head2 get_affiliate_clients

This method retrieves affiliate clients associated with the given affiliate ID.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - id: The ID of the affiliate.

=item - binary_user_id: The binary user ID of the affiliate.

=item - platform: The platform of the affiliate.

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

A hash reference containing either an error message or the list of affiliate clients.

=back

=cut

    method get_affiliate_clients ($args) {
        try {
            my $output = $commission_db->dbic->run(
                fixup => sub {
                    my $sth = $_->prepare(
                        qq{
                            SELECT * FROM affiliate.get_affiliate_clients(?, ?, ?, ?)
                        }
                    );
                    $sth->execute($args->{id}, $args->{binary_user_id}, $args->{platform}, $args->{affiliate_external_id});
                    my $result = $sth->fetchall_arrayref({});
                    return $result;
                });
            return {
                affiliate_clients => $output,
                success           => 1
            };
        } catch ($e) {
            return {
                error   => "Error getting affiliate clients: $e",
                success => 0
            };
        }
    }

}

1;

