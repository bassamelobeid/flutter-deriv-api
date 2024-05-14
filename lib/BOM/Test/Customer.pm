package BOM::Test::Customer;
use strict;
use warnings;

use BOM::User;
use BOM::Test::Data::Utility::UnitTestDatabase;

=head1 NAME

BOM::Test::Customer - Manages customer information and client interactions for brokerage services.

=head1 SYNOPSIS

  use BOM::Test::Customer;

  my $customer = BOM::Test::Customer->create({
        email    => 'example@email.com',
        password => 'hashed_password',
      }
      clients  => [
          { name = 'MF', broker_code => 'MF', default_account => 'USD' },
          { name = 'VRTC', broker_code => 'VRTC' },
          { name = 'CR1', broker_code => 'CR' },
          { name = 'CR2', broker_code => 'CR' },
      ],
  );

=head1 DESCRIPTION

This module provides methods to manage a customer's credentials and their interactions with different brokerage clients. It supports initialization of client-specific settings and caching of client data.

=cut

sub create {
    my ($class, $user_args, $clients) = @_;

    # Initialize user
    my $user = BOM::User->create(%{$user_args});

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
    for my $client (@{$clients}) {

        my $name            = $client->{name};
        my $broker_code     = $client->{broker_code};
        my $default_account = $client->{default_account} // undef;
        die "Missing 'name'"        unless defined $name;
        die "Missing 'broker_code'" unless defined $broker_code;

        my $client = BOM::Test::Data::Utility::UnitTestDatabase::create_client({
                broker_code    => $broker_code,
                email          => $user->email,
                binary_user_id => $user->id,
                (defined $user_args->{citizen}                ? (citizen   => $user_args->{citizen})                : ()),
                (defined $user_args->{residence}              ? (residence => $user_args->{residence})              : ()),
                (defined $user_args->{fatca_declaration_time} ? (residence => $user_args->{fatca_declaration_time}) : ()),
                (defined $user_args->{fatca_declaration}      ? (residence => $user_args->{fatca_declaration})      : ()),
                # There is a hidden constraint here non_pep can only be null IF its a virtual client
                (
                    ($broker_code =~ /^VR/ && exists $user_args->{non_pep_declaration_time})
                        || defined $user_args->{non_pep_declaration_time} ? (non_pep_declaration_time => $user_args->{non_pep_declaration_time}) : ()
                ),
            });

        if (exists($client->{default_account})) {
            $client->set_default_account($default_account);
        }
        $user->add_client($client);

        $self->{clients}{$name}  = $client;
        $self->{loginids}{$name} = $client->loginid;
        $self->{tokens}{$name}   = BOM::Platform::Token::API->new->create_token($client->loginid, 'Test Token');
    }

    return $self;
}

=head2 get_client_loginid

Retrieves the user ID for a specified customer

=cut

sub get_user_id {
    my ($self) = @_;
    return $self->{user}->id;
}

=head2 get_client_loginid

Retrieves the email for a customer

=cut

sub get_email {
    my ($self) = @_;
    return $self->{user}->email;
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

=head2 get_client_token

Retrieves the client token for a specified name.

=cut

sub get_client_token {
    my ($self, $name) = @_;
    return $self->{tokens}{$name};
}

1;
