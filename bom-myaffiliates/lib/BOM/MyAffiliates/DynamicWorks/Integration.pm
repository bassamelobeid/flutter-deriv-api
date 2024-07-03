
package BOM::MyAffiliates::DynamicWorks::Integration;
use Object::Pad;

=head1 NAME

BOM::MyAffiliates::DynamicWorks::Integration

=head1 DESCRIPTION

Integration - A Perl class for providing integration point and one stop solution for creating new user and trading account on DW

=cut

=head1 FIELDS

=head2 $commission_db

An instance of C<BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel> used for interacting with the commission database.

=head2 $syn_crm_requester

An instance of C<BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester> used for making requests to the Syntellicore CRM system.

=head2 $syn_requester

An instance of C<BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester> used for making general requests to the Syntellicore system.

=cut

use strict;
use warnings;
use HTTP::Tiny;
use JSON::MaybeUTF8 qw(:v1);
use BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester;
use BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester;
use BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel;
use Business::Config::Account;

use Business::Config::Country::Registry;
use Log::Any qw($log);
use Syntax::Keyword::Try;

use BOM::Config;
use BOM::User;

use constant PROVIDER => 'dynamicworks';

class BOM::MyAffiliates::DynamicWorks::Integration {

    field $commission_db;
    field $syn_crm_requester;
    field $syn_requester;

    BUILD {
        $commission_db     = BOM::MyAffiliates::DynamicWorks::DataBase::CommissionDBModel->new();
        $syn_crm_requester = BOM::MyAffiliates::DynamicWorks::SyntellicoreCRMRequester->new();
        $syn_requester     = BOM::MyAffiliates::DynamicWorks::SyntellicoreRequester->new();
    }

=head1 METHODS

=head2 new

This method initializes the class with the configuration for the commission database and the Syntellicore CRM system.

=cut

=head2 get_country_mapper

This method returns the country mapper from cache or refreshes it if not found in cache.

=over 4

=item * Returns

The method returns a hash reference containing the country mapper.

=back

=cut

    method get_country_mapper {
        my $country_mapper = Cache::RedisDB->get('dw_api', 'country_mapper');
        if (!defined $country_mapper) {
            $country_mapper = $self->refresh_country_mapper();
        }
        return $country_mapper;
    }

=head2 refresh_country_mapper

This method refreshes the country mapper by fetching from DW API and stores it in cache.

=over 4

=item * Returns

The method returns a hash reference containing the country mapper.

=back

=cut

    method refresh_country_mapper {
        my $countries = $syn_requester->getCountries();
        die 'Error getting countries' unless defined $countries->{data} && scalar @{$countries->{data}} > 0;
        my $country_mapper = {map { $_->{iso_alpha2_code} => $_->{country_id} } @{$countries->{data}}};
        Cache::RedisDB->set('dw_api', 'country_mapper', $country_mapper, 86400);
        return $country_mapper;

    }

=head2 get_client_country_id

This method returns the country ID of the client.

=over 4

=item * Arguments

=over 4

=item client_residence: The residence of the client.

=back

=item * Returns

The method returns the country ID of the client.

=back

=cut

    method get_client_country_id ($client_residence) {
        return $self->get_country_mapper->{uc($client_residence)};
    }

=head2 create_user

This method creates a new user on DW.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - user: The user object.

=item - sidc: The SIDC of the user.

=back

=item * Returns

The method returns a hash reference containing the user details.

=back

=cut

    method create_user ($args) {

        my $user = $args->{user};
        my $sidc = $args->{sidc};

        my @clients      = $user->clients(include_disabled => 1);
        my $first_client = $clients[0];

        my $request_args = {
            first_name => $user->{first_name} // $first_client->{first_name},
            last_name  => $user->{last_name}  // $first_client->{last_name},
            email      => $user->{email}      // $first_client->{email},
            password   => "Abcd12345",                                                                    #TODO: Make it random and save it somewhere,
            country_id => $self->get_client_country_id($user->{residence} // $first_client->{residence}),
            currency   => $first_client->currency,
            is_ib      => $args->{is_ib} // 0,
            sidc       => $sidc,
        };

        my $partner = $syn_requester->createUser($request_args);

        die 'Error creating user' unless $partner;

        die 'Error creating partner for user: ' . $partner->{info}->{message}
            unless scalar @{$partner->{data}} > 0 && defined $partner->{data}[0]->{user};

        return $partner->{data}[0];

    }

=head2 get_sidcs

This method returns the SIDCs of the affiliate.

=over 4

=item * Arguments

=over 4

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

The method returns an array ref of hashrefs containing SIDCs of the affiliate.

=back

=cut

    method get_sidcs ($affiliate_external_id) {
        my $response = $syn_crm_requester->getPartnerCampaigns({external_affiliate_id => $affiliate_external_id});

        die 'Error getting campaigns for affiliate_id: ' . $response->{info}->{message} unless $response->{data} && scalar @{$response->{data}};

        my $sidcs = $response->{data};

        return $sidcs;
    }

=head2 get_account_id

This method returns the account ID of the client by getting the broker code and replacing it with an ID from dw_broker_code_mapper
i.e for CR90000001, it will return dw_broker_code_mapper->{CR} . '90000001'

=over 4

=item * Arguments

=over 4

=item - client_loginid: The login ID of the client.

=back

=item * Returns

string - The account ID of the client.

=back

=cut

    method get_account_id ($client_loginid) {
        my $broker_code_mapper = my $config = Business::Config::Account->new()->dw_broker_code_mapper();

        my ($broker_code) = $client_loginid =~ /^([A-Z]+)[0-9]+$/;

        my $broker_id = $broker_code_mapper->{$broker_code};

        return $broker_id . substr($client_loginid, length($broker_code));

    }

=head2 get_partner_id_from_sidc

This method returns the partner ID from the SIDC.

=over 4

=item * Arguments

=over 4

=item - sidc: The SIDC of the affiliate.

=back

=item * Returns

string - The partner ID of the affiliate.

=back

=cut

    method get_partner_id_from_sidc ($sidc) {
        my $response = $syn_crm_requester->getPartnerCampaigns({sidc => $sidc});
        die 'Error getting partner from sidc: ' . $response->{info}->{message} unless scalar @{$response->{data}};
        return $response->{data}[0]->{introducer};
    }

=head2 set_trading_account

This method sets the trading account for the client.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - customer_no: The customer number of the client.

=item - client_loginid: The login ID of the client.

=item - at_id: The AT ID of the client.

=item - is_demo: The demo status of the client.

=item - is_ib: The IB status of the client.

=item - eq_group_id: The EQ group ID of the client.

=item - sql_only: The SQL only status of the client.

=back

=item * Returns

The method returns a hash reference containing the account details.

=back

=cut

    method set_trading_account ($args) {

        my $account_id = $self->get_account_id($args->{client_loginid});

        my $response = $syn_crm_requester->setCustomerTradingAccount({
                customer_no => $args->{customer_no},
                account_id  => $account_id,
                at_id       => $args->{at_id}       // 1,
                is_demo     => $args->{is_demo}     // 0,
                is_ib       => $args->{is_ib}       // 0,
                eq_group_id => $args->{eq_group_id} // 1,
                sql_only    => $args->{sql_only}    // 1,

        });

        die 'Error setting trading account for client: ' . $response->{info}->{message}
            unless defined $response->{data} && scalar @{$response->{data}} && defined $response->{data}->[0]->{account_id};

        return $response->{data}[0];

    }

=head2 register_user

This method registers a user on DW.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - user: The user object.

=item - affiliate_external_id: The external ID of the affiliate.

=item - sidc: The SIDC of the user.

=item - existing_affiliated_client: The existing affiliated client.

=back

=item * Returns

The method returns a hash reference containing the user details.

=back

=cut

    method register_user ($args) {
        my $user                       = $args->{user};
        my $affiliate_external_id      = $args->{affiliate_external_id};
        my $sidc                       = $args->{sidc};
        my $existing_affiliated_client = $args->{existing_affiliated_client};

        $existing_affiliated_client = $user->get_affiliated_client_details({provider => PROVIDER}) if !defined $existing_affiliated_client;

        if (!defined $existing_affiliated_client) {
            $user->set_affiliated_client_details({partner_token => $sidc, provider => PROVIDER});
            $existing_affiliated_client = $user->get_affiliated_client_details({provider => PROVIDER});
        }

        $sidc = $existing_affiliated_client->{partner_token};

        if (!defined $existing_affiliated_client->{user_external_id}) {
            my $dw_user = $self->create_user({user => $user, affiliate_external_id => $affiliate_external_id, sidc => $sidc});

            my $dw_user_customer_no = $dw_user->{user};
            $user->update_affiliated_client_details({partner_token => $sidc, provider => PROVIDER, client_id => $dw_user_customer_no});
            $existing_affiliated_client->{user_external_id} = $dw_user_customer_no;
            $existing_affiliated_client->{partner_token}    = $sidc;
        }

        return $existing_affiliated_client;
    }

=head2 register_trading_account

This method registers a trading account for the client on DW.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - affiliate_external_id: The external ID of the affiliate.

=item - affiliate_id: The ID of the affiliate.

=item - binary_user_id: The ID of the user.

=item - client_loginid: The login ID of the client.

=item - platform: The platform of the client.

=item - user_external_id: The external ID of the user.

=back

=item * Returns

The method returns a hash reference containing the account details.

=back

=cut

    method register_trading_account ($args) {
        my $affiliate_external_id = $args->{affiliate_external_id};
        my $affiliate_id          = $args->{affiliate_id};
        my $binary_user_id        = $args->{binary_user_id};
        my $client_loginid        = $args->{client_loginid};
        my $platform              = $args->{platform};
        my $user_external_id      = $args->{user_external_id};

        my $existing_affiliate_client = $commission_db->get_affiliate_clients({
                affiliate_external_id => $affiliate_external_id,
                platform              => $platform,
                binary_user_id        => $binary_user_id,
                id                    => $client_loginid
            })->{affiliate_clients}->[0];

        if (!defined $existing_affiliate_client) {

            my $response = $self->set_trading_account({
                customer_no    => $user_external_id,
                client_loginid => $client_loginid
            });

            $commission_db->upsert_affiliate_client_with_mapping({
                affiliate_client_id        => $client_loginid,
                affiliate_id               => $affiliate_id,
                platform                   => $platform,
                binary_user_id             => $binary_user_id,
                client_loginid_external_id => $response->{account_id},
                user_external_id           => $user_external_id,
                provider                   => PROVIDER
            });

            $existing_affiliate_client = $commission_db->get_affiliate_clients({
                    id             => $client_loginid,
                    affiliate_id   => $affiliate_external_id,
                    provider       => $platform,
                    binary_user_id => $binary_user_id
                })->{affiliate_clients}->[0];
        }

        return $existing_affiliate_client;
    }

=head2 register_client

This method registers a client on DW.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - client_loginid: The login ID of the client.

=item - user: The user object.

=item - binary_user_id: The ID of the user.

=item - sidc: The SIDC of the user.

=item - existing_affiliated_client: The existing affiliated client.

=item - platform: The platform of the client.

=item - affiliate_id: The ID of the affiliate.

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

The method returns a hash reference containing the account details.

=back

=cut

    method register_client ($args) {
        my $client_loginid             = $args->{client_loginid};
        my $user                       = $args->{user};
        my $binary_user_id             = $user->id;
        my $sidc                       = $args->{sidc};
        my $existing_affiliated_client = $args->{existing_affiliated_client};
        my $platform                   = $args->{platform};
        my $affiliate_id               = $args->{affiliate_id};
        my $affiliate_external_id      = $args->{affiliate_external_id};

        die 'client_loginid is required'        if !defined $client_loginid;
        die 'user is required'                  if !defined $user;
        die 'binary_user_id is required'        if !defined $binary_user_id;
        die 'sidc is required'                  if !defined $sidc;
        die 'platform is required'              if !defined $platform;
        die 'affiliate_id is required'          if !defined $affiliate_id;
        die 'affiliate_external_id is required' if !defined $affiliate_external_id;

        try {

            my $existing_affiliated_client = $self->register_user({
                user                       => $user,
                affiliate_external_id      => $affiliate_external_id,
                sidc                       => $sidc,
                existing_affiliated_client => $existing_affiliated_client
            });

            $self->register_trading_account({
                    affiliate_external_id => $affiliate_external_id,
                    affiliate_id          => $affiliate_id,
                    binary_user_id        => $binary_user_id,
                    client_loginid        => $client_loginid,
                    platform              => $platform,
                    user_external_id      => $existing_affiliated_client->{user_external_id}});

            # if mt5 {update_user mt5}

            return {
                success => 1,
            };

        } catch ($e) {
            $commission_db->add_pending_affiliate_client({
                client_loginid => $client_loginid,
                binary_user_id => $binary_user_id,
                provider       => PROVIDER
            });
            $log->errorf('Error linking client %s to affiliate %s: %s', $args->{client_loginid}, $args->{affiliate_external_id}, $e);
            return {
                success => 0,
                error   => $e,
            };
        }

    }

=head2 link_user_to_affiliate

This method links the user to the affiliate.

=over 4

=item * Arguments

The method expects a hash reference containing the following

=over 4

=item - binary_user_id: The ID of the user.

=item - sidc: The SIDC of the user.

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

The method returns a hash reference containing the result of the operation.

=back

=cut

    method link_user_to_affiliate ($args) {

        my $binary_user_id = $args->{binary_user_id};

        die 'binary_user_id is required' if !defined $binary_user_id;

        my $user = BOM::User->new(id => $binary_user_id);

        my $sidc                  = $args->{sidc}                  // undef;
        my $affiliate_external_id = $args->{affiliate_external_id} // undef;

        my $existing_affiliated_client;

        if (!defined $sidc) {
            $existing_affiliated_client = $user->get_affiliated_client_details({provider => PROVIDER});
            return undef if !defined $existing_affiliated_client;
            $sidc = $existing_affiliated_client->{partner_token};
            die "'sidc' is required as existing affiliated_client with partner token is not found" if !defined $sidc;
        }

        if (!defined $affiliate_external_id) {
            my $existing_affiliate_client_for_user =
                $commission_db->get_affiliate_clients({binary_user_id => $binary_user_id, provider => PROVIDER})->{affiliate_clients}->[0];
            $affiliate_external_id = $existing_affiliate_client_for_user->{affiliate_id};
            $affiliate_external_id = $self->get_partner_id_from_sidc($sidc) if !defined $affiliate_external_id;
        }

        my $affiliate = $commission_db->get_affiliates({affiliate_external_id => $affiliate_external_id})->{affiliates}->[0];

        die 'Affiliate not found with external_id: ' . $affiliate_external_id unless defined $affiliate;

        my @clients = values %{$user->loginid_details};

        @clients = grep { !$_->{is_virtual} && !defined $_->{status} } @clients;

        my $result = {
            success        => 1,
            error_loginids => []};

        for my $client (@clients) {
            my $client_registered = $self->register_client({
                client_loginid => $client->{loginid},
                user           => $user,
                provider       => PROVIDER,
                platform       => $client->{platform},
                ,
                # trading_group_id => 0,
                affiliate_external_id      => $affiliate->{external_affiliate_id},
                affiliate_id               => $affiliate->{id},
                sidc                       => $sidc,
                existing_affiliated_client => $existing_affiliated_client,
            });

            if ($client_registered->{success} == 0) {
                push @{$result->{errors}},
                    {
                    loginid => $client->{loginid},
                    error   => $client_registered->{error},
                    };
                $result->{success} = 0;
            }
        }

        return $result;

    }

=head2 get_user_profiles

This method gets the user profiles of the DW user.

=over 4

=item * Arguments

The method expects a scalar value following

=over 4

=item - affiliate_external_id: The external ID of the affiliate.

=back

=item * Returns

The method returns a hash reference containing the result of the operation.

=back

=cut

    method get_user_profiles ($external_affiliate_id) {
        my $response = $syn_crm_requester->getProfiles($external_affiliate_id);

        if (exists $response->{data} && ref($response->{data}) eq 'ARRAY' && @{$response->{data}} == 0) {
            $log->warnf('Error getting profiles for dyanmicworks user %s: ', $external_affiliate_id);
            return 0;
        }

        my $profiles = $response->{data};

        return $profiles;
    }

}
1;
