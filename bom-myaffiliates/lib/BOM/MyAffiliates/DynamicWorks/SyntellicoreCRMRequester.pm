package BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester;

use Object::Pad;

=head1 NAME

SyntellicoreCRMRequester - A Perl class for interacting with the Syntellicore CRM API to create new users using HTTP::Tiny.

=head1 DESCRIPTION

This module provides a simple interface for interacting with the Syntellicore CRM API

=cut

=head1 METHODS

=head2 new

This method initializes the class with the configuration for the Syntellicore CRM system.

=cut

use strict;
use warnings;
use BOM::Config;

class BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester :isa(BOM::MyAffiliates::DynamicWorks::Requester) {

=head2 userLogin

This method logs in the user to the Syntellicore CRM system.

=over 4

=item * Returns

A hash reference containing the response from the Syntellicore CRM system.

=back

=cut

    method userLogin () {
        my $content = {
            login    => $self->user_login,
            password => $self->user_password
        };

        return $self->api_request({
            method              => 'POST',
            api                 => 'user_login',
            content             => $content,
            do_not_authenticate => 1
        });
    }

=head2 getConfig

This method returns the configuration for the Syntellicore CRM system which is used by parent class's constructor.

=over 4

=item * Returns

A hash reference containing the configuration for the Syntellicore system.

=back

=cut

    method getConfig {

        my $config = BOM::Config::third_party()->{dynamic_works}->{syntellicore_crm};

        die "Config not defined for syntellicore_crm" unless $config;

        return $config;
    }

=head2 getPartnerCampaigns

This method returns a list of partner campaigns.

=over 4

=item * $args

A hash reference containing the following

=over 4

=item - external_affiliate_id: The external affiliate ID.

=item - sidc: The SIDC.

=back

=item * Returns

A hash reference containing the response from the Syntellicore CRM system.

=back

=cut

    method getPartnerCampaigns ($args) {
        my $external_affiliate_id = $args->{external_affiliate_id};
        my $sidc                  = $args->{sidc};

        die "sidc OR external_affiliate_id is required" unless defined $sidc || defined $external_affiliate_id;
        #die "External affiliate ID (external_affiliate_id)" unless defined $external_affiliate_id;

        my $content = {
            login       => $self->user_login,
            customer_no => $external_affiliate_id,
            sidc        => $sidc,
        };

        return $self->api_request({
            method  => 'POST',
            api     => 'get_partner_campaigns',
            content => $content
        });
    }

=head2 setCustomerTradingAccount

This method sets the customer trading account.

=over 4

=item * $args

A hash reference containing the following

=over 4

=item - customer_no: The client external ID.

=item - account_id: The client broker code mapped login ID.

=item - at_id: The AT ID.

=item - is_demo: Whether the account is a demo account.

=item - is_ib: Whether the account is an IB account.

=item - eq_group_id: The EQ group ID.

=item - sql_only.

=back

=item * Returns

A hash reference containing the response from the Syntellicore CRM system.

=back

=cut

    method setCustomerTradingAccount ($args) {
        die "client external id (customer_no)"               unless defined $args->{customer_no};
        die "client broker code mapped loginid (account_id)" unless defined $args->{account_id};

        my $content = {
            login       => $self->user_login,
            customer_no => $args->{customer_no},
            at_id       => $args->{at_id},
            account_id  => $args->{account_id},
            is_demo     => $args->{is_demo}     // 0,
            is_ib       => $args->{is_ib}       // 0,
            eq_group_id => $args->{eq_group_id} // 1,
            sql_only    => $args->{sql_only}    // 1,
        };

        return $self->api_request({
            method  => 'POST',
            api     => 'set_customer_trading_account',
            content => $content
        });
    }

=head2 getProfiles

This method gets the user profiles.

=over 4

=item * $args

following scalar value

=over 4

=item - $external_affiliate_id: The client external ID.

=back

=item * Returns

A hash reference containing the response from the Syntellicore CRM system.

=back

=cut

    method getProfiles ($external_affiliate_id) {
        die "External affiliate ID (external_affiliate_id)" unless defined $external_affiliate_id;

        my $content = {
            login       => $self->user_login,
            customer_no => $external_affiliate_id
        };

        return $self->api_request({
            method  => 'POST',
            api     => 'get_profiles',
            content => $content
        });
    }

}

1;
