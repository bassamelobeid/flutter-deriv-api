package BOM::Config::MT5;

=head1 NAME

BOM::Config::MT5

=head1 DESCRIPTION

This module has helper functions to return mt5 routing and server config

It does not exports these functions by default.

=cut

use strict;
use warnings;

use Syntax::Keyword::Try;

use BOM::Config;

=head2 new

Create a new object of MT5 config

    BOM::Config::MT5->new(server_id => 'real01', type => real)

=cut

sub new {
    my ($class, %args) = @_;

    return bless \%args, $class;
}

=head2 server_geolocation

    $obj->server_geolocation();

Get the geolocation details for the mt5 server

Returns a hash containing geolocation details containing the following keys:

=over 4

=item * region; region where server is location, example Europe

=item * location; location in the region, example Ireland

=item * sequence; sequence number of server in the region

=back

=cut

sub server_geolocation {
    my $self = shift;

    my $server = $self->server_by_id();

    return $server->{$self->{server_id}}{geolocation};
}

=head2 server_by_id

    $obj->server_by_id();

Get the server details of the mt5 server for the corresponding mt5

=cut

sub server_by_id {
    my $self = shift;

    die "Invalid server id. Please provide a valid server id." unless $self->{server_id};

    my $config = $self->config();

    my $details = $self->server_details();

    die 'Provided server id does not exist in our config.' unless exists $config->{$details->{type}}{$details->{number}};

    return create_server_structure(
        server_type => $details->{type},
        server      => $config->{$details->{type}}{$details->{number}},
    );
}

=head2 servers

    $obj->servers()

Get the list of servers supported, filtered to type if provided

=cut

sub servers {
    my $self = shift;

    my $mt5_config = $self->config();
    return undef unless $mt5_config;

    my @servers = ();

    foreach my $server_type (sort keys %$mt5_config) {
        next if $self->{type} and $self->{type} ne $server_type;

        foreach my $server (sort keys %{$mt5_config->{$server_type}}) {
            push @servers,
                create_server_structure(
                server_type => $server_type,
                server      => $mt5_config->{$server_type}{$server},
                );
        }
    }

    return \@servers;
}

=head2 create_server_structure

    create_server_structure(server_type => real, server => $server_hash)

Create a hash object of required keys to return

Takes a single C<$params> hashref containing the following keys:

=over 4

=item * args which contains the following keys:

=over 4

=item * server_type; type of the server, real or demo

=item * server; hash of server from config file

=back

=back

=cut

sub create_server_structure {
    my (%args) = @_;

    return undef unless $args{server_type};

    return undef unless $args{server};

    my $server_id = $args{server_type} . $args{server}->{group_suffix};

    return {
        $server_id => {
            geolocation => {
                location => $args{server}->{geolocation}{location},
                region   => $args{server}->{geolocation}{region},
                sequence => $args{server}->{geolocation}{sequence},
            },
            environment => $args{server}->{environment},
        },
    };
}

=head2 server_details

    $obj->server_details()

Get the server details; currently, type and number

=cut

sub server_details {
    my $self = shift;

    die "Invalid server id. Please provide a valid server id." unless $self->{server_id};

    my ($server_type, $server_number) = $self->{server_id} =~ /^([a-z]+)(\d+)$/;

    die 'Cannot extract server type and number from the server id provided.' unless $server_type and $server_number;

    return {
        type   => $server_type,
        number => $server_number,
    };
}

=head2 config

Returns the whole server config

=cut

sub config {
    my $mt5_config = BOM::Config::mt5_webapi_config();

    die "Cannot load mt5 webapi config." unless $mt5_config;

    return $mt5_config;
}

1;
