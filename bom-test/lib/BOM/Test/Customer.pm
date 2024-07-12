package BOM::Test::Customer;
use strict;
use warnings;

use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase;
use UUID::Tiny;
use Digest::SHA qw(sha1_hex);
use Storable 'dclone';

=head1 NAME

BOM::Test::Customer - Manages customer information and client interactions for brokerage services.

=head1 SYNOPSIS

  use BOM::Test::Customer;

  my $customer = BOM::Test::Customer->create(
        email    => 'example@email.com', (optional)
        password => 'hashed_password', (optional)
        <other user attributes>,
        clients  => [
          { name = 'MF', broker_code => 'MF', default_account => 'USD' },
          { name = 'VRTC', broker_code => 'VRTC' },
          { name = 'CR1', broker_code => 'CR' },
          { name = 'CR2', broker_code => 'CR' },
        ],
  );

=head1 DESCRIPTION

This module provides methods to manage a customer's credentials and their interactions with different brokerage clients. It supports initialization of client-specific settings and caching of client data.

=head2 create

Function that returns a customer object with the specified attributes and clients.

=cut

sub create {
    my ($class, %customer_attributes) = @_;

    # Extract clients from the attributes
    die "Missing customer attributes" unless $customer_attributes{clients};
    my $clients = delete $customer_attributes{clients} || [];

    # Add email if not provided
    $customer_attributes{email} //= get_random_email_address();
    # Add password if not provided
    $customer_attributes{password} //= 'secret_password';

    # Initialize user
    my $user = BOM::User->create(%customer_attributes);

    # ******************************************************************************
    # UNDER NO CIRCUMSTANCES SHOULD YOU ATTEMPT TO ACCESS THESE OBJECTS DIRECTLY
    # Use the provided methods to access the data as needed as these objects are
    # subject to change without notice.
    # ******************************************************************************

    my $self = bless {}, $class;
    $self->{user}     = $user;
    $self->{clients}  = {};
    $self->{loginids} = {};
    $self->{tokens}   = {};

    # ******************************************************************************
    # UNDER NO CIRCUMSTANCES SHOULD YOU ATTEMPT TO ACCESS THESE OBJECTS DIRECTLY
    # Use the provided methods to access the data as needed as these objects are
    # subject to change without notice.
    # ******************************************************************************

    # Initialize clients
    for my $client_request (@$clients) {
        my $name = $client_request->{name};
        $self->_create_client($name, $client_request, \%customer_attributes);
    }

    return $self;
}

=head2 get_service_contexts

Static function that returns all available contexts for all services

=cut

sub get_service_contexts {
    return {
        user => get_user_service_context(),
    };
}

=head2 get_user_context

Static function that returns a context for use with the user service calls

=cut

sub get_user_service_context {
    return {
        'correlation_id' => UUID::Tiny::create_UUID_as_string(UUID::Tiny::UUID_V4),
        'auth_token'     => 'Test Token, just for testing',
        'environment'    => 'Test Environment',
    };
}

=head2 get_random_email_address

Static function that returns random but unique email address

=cut

sub get_random_email_address {
    my $hash = substr(sha1_hex(time . $$ . rand), 0, 20);
    return "$hash\@example.com";
}

=head2 get_user_id

Retrieves the user ID for a specified customer

=cut

sub get_user_id {
    my ($self) = @_;
    return $self->{user}->id;
}

=head2 get_email

Retrieves the email for a customer

=cut

sub get_email {
    my ($self) = @_;
    return $self->{user}->email;
}

=head2 get_first_name

Retrieves the first name for a customer

=cut

sub get_first_name {
    my ($self) = @_;

    my $user_data = BOM::Service::user(
        context    => $self->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $self->{user}->id,
        attributes => [qw(first_name)],
    );
    die "User service failure $user_data->{message}" unless $user_data->{status} eq 'ok';

    return $user_data->{attributes}{first_name};
}

=head2 get_last_name

Retrieves the last name for a customer

=cut

sub get_last_name {
    my ($self) = @_;

    my $user_data = BOM::Service::user(
        context    => $self->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $self->{user}->id,
        attributes => [qw(last_name)],
    );
    die "User service failure $user_data->{message}" unless $user_data->{status} eq 'ok';

    return $user_data->{attributes}{last_name};
}

=head2 get_full_name

Retrieves the name for a customer

=cut

sub get_full_name {
    my ($self) = @_;

    my $user_data = BOM::Service::user(
        context    => $self->get_user_service_context(),
        command    => 'get_attributes',
        user_id    => $self->{user}->id,
        attributes => [qw(full_name)],
    );
    die "User service failure $user_data->{message}" unless $user_data->{status} eq 'ok';

    return $user_data->{attributes}{full_name};
}

=head2 get_client_loginid

Retrieves the login ID for a specified name.

=cut

sub get_client_loginid {
    my ($self, $name) = @_;
    return $self->{loginids}{$name};
}

=head2 get_client_object

Retrieves the client object for a specified name.

=cut

sub get_client_object {
    my ($self, $name) = @_;
    return $self->{clients}{$name};
}

=head2 get_all_client_objects

Retrieves an array of all the clients for this customer

=cut

sub get_all_client_objects {
    my ($self) = @_;
    return values %{$self->{clients}};
}

=head2 get_client_token

Retrieves the client token for a specified name.

=cut

sub get_client_token {
    my ($self, $name, $scope) = @_;
    if (defined $scope) {
        return BOM::Platform::Token::API->new->create_token($self->{loginids}{$name}, 'Test Token', $scope);
    } else {
        return $self->{tokens}{$name};
    }
}

=head2 add_loginid

Adds a loginid with no client for the specified login id, also returns client object added.

=cut

sub add_loginid {
    my ($self, $name, $loginid, $platform, $account_type, $currency, $attributes, $link_to_wallet_loginid) = @_;

    $self->{user}->add_loginid($loginid, $platform, $account_type, $currency, $attributes, $link_to_wallet_loginid);
    $self->{loginids}{$name} = $loginid;

    return $loginid;
}

=head2 add_client

Adds a client for the specified login id, also returns client object added.

=cut

sub add_client {
    my ($self, $name, $loginid, $link_to_wallet_loginid) = @_;

    my $new_client = BOM::User::Client->new({loginid => $loginid});
    $self->{user}->add_client($new_client, $link_to_wallet_loginid);
    $new_client->binary_user_id($self->{user}->id);
    $new_client->save;

    $self->{clients}{$name}  = $new_client;
    $self->{loginids}{$name} = $new_client->loginid;
    $self->{tokens}{$name}   = BOM::Platform::Token::API->new->create_token($new_client->loginid, 'Test Token');

    return $new_client;
}

=head2 create_client

Creates and add a client given the passed client parameters

=cut

sub create_client {
    my ($self, %client_request) = @_;

    # Extract clients from the attributes
    die "Missing client name" unless $client_request{name};
    my $name = delete $client_request{name};

    return $self->_create_client($name, \%client_request, {});
}

=head2 _create_client

Private function to create and add a client to the object

=cut

sub _create_client {
    my ($self, $name, $client_request, $customer_attributes) = @_;
    my $broker_code = $client_request->{broker_code};
    die "Missing 'name'"        unless defined $name;
    die "Missing 'broker_code'" unless defined $broker_code;

    # Deep copy the client request and customer attributes to avoid modifying the original data
    $client_request      = dclone($client_request);
    $customer_attributes = dclone($customer_attributes);

    my $client_keys = [
        # non_pep_declaration_time is removed as special case, see below
        qw(account_opening_reason address_city address_line_1 address_line_2 address_postcode address_state allow_login aml_risk_classification cashier_setting_password checked_affiliate_exposures citizen comment custom_max_acbal custom_max_daily_turnover custom_max_payout date_joined date_of_birth default_client fatca_declaration_time fatca_declaration first_name first_time_login gender last_name latest_environment mifir_id myaffiliates_token myaffiliates_token_registered payment_agent_withdrawal_expiration_date phone place_of_birth residence restricted_ip_address salutation secret_answer secret_question small_timer source tax_identification_number tax_residence)
    ];

    my $client_args = {
        broker_code    => $broker_code,
        email          => $self->{user}->email,
        binary_user_id => $self->{user}->id,
        (exists $client_request->{loginid}      ? (loginid      => $client_request->{loginid})      : ()),
        (exists $client_request->{account_type} ? (account_type => $client_request->{account_type}) : ()),
        # There is a hidden constraint here non_pep can only be null IF its a virtual client
        (
            ($broker_code =~ /^VR/ && exists $customer_attributes->{non_pep_declaration_time})
                || defined $customer_attributes->{non_pep_declaration_time}
            ? (non_pep_declaration_time => $customer_attributes->{non_pep_declaration_time})
            : ()
        ),
    };

    # Copy the relevant keys from the customer attributes to the client arguments
    for my $key (@{$client_keys}) {
        # Customer attributes take priority over client request
        $client_args->{$key} = $client_request->{$key}      if exists $client_request->{$key};
        $client_args->{$key} = $customer_attributes->{$key} if exists $customer_attributes->{$key};
    }
    my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client($client_args);

    if (exists($client_request->{default_account})) {
        $client->set_default_account($client_request->{default_account});
    }

    $self->{user}->add_client($client);

    $self->{clients}{$name}  = $client;
    $self->{loginids}{$name} = $client->loginid;
    $self->{tokens}{$name}   = BOM::Platform::Token::API->new->create_token($client->loginid, 'Test Token');

    return $client;
}

1;
