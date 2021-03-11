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
use List::Util qw(any);

use BOM::Config::Runtime;
use BOM::Config;

=head2 new

Create a new object of MT5 config

    # by group
    BOM::Config::MT5->new(group => 'real\p01_ts01\synthetic\svg_std_usd')
    BOM::Config::MT5->new(group => 'real01\synthetic\svg_std_usd')
    BOM::Config::MT5->new(group => 'real\svg')

    # by server type and group tpe
    BOM::Config::MT5->new(group_type 'real', server_type=> 'p01_ts01')

=cut

sub new {
    my ($class, %args) = @_;

    if ($args{group}) {
        my $group_info = $class->groups_config()->{$args{group}};

        if (not defined $group_info) {
            ($args{group_type}, $args{server_type}) = $args{group} =~ /^(real|demo)\\(p\d{2}_ts\d{2})\\/;
        } else {
            $args{group_type}  = $group_info->{account_type};
            $args{server_type} = $group_info->{server};
        }

        die 'Invalid group [' . $args{group} . ']' unless $args{group_type} and $args{server_type};
    }

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
    return $server->{$self->{server_type}}{geolocation};
}

=head2 server_environment

    $obj->server_environment();

Get the environment for the mt5 server. i.e. Deriv-Server

Returns a string 

=cut

sub server_environment {
    my $self = shift;

    my $server = $self->server_by_id();
    return $server->{$self->{server_type}}{environment};
}

=head2 server_by_id

    $obj->server_by_id();

Get the server details of the mt5 server for the corresponding mt5

=cut

sub server_by_id {
    my $self = shift;

    my $config = $self->webapi_config();

    my $server = $config->{$self->{group_type}}{$self->{server_type}};

    unless ($server) {
        die 'Cannot extract server information from group[' . $self->{group} . ']' if $self->{group};
        die 'Cannot extract server information from  server type[' . $self->{server_type} . '] and group type[' . $self->{group_type} . ']';
    }

    return create_server_structure(
        server_type => $self->{server_type},
        server      => $server,
    );
}

=head2 server_by_country

# To get all trade servers for Indonesia
->server_by_country('id');

# To get all real trade servers for Indonesia
->server_by_country('id', {group_type => 'real'});

Returns a hash reference.

=cut

sub server_by_country {
    my ($self, $country_code, $args) = @_;

    die "country code is requird" unless $country_code;

    my $routing_config = $self->routing_config;
    my ($group_type, $market_type) = @{$args}{'group_type', 'market_type'};
    my $servers;

    foreach my $group (keys %$routing_config) {
        next if defined $group_type and $group_type ne $group;
        foreach my $market (keys %{$routing_config->{$group}{$country_code}}) {
            next if defined $market_type and $market_type ne $market;
            $servers->{$group}{$market} = $self->_generate_server_info($group, $routing_config->{$group}{$country_code}{$market}{servers});
        }
    }

    return $servers;
}

=head2 _generate_server_info

Sorted (by recommended first) server information

=cut

sub _generate_server_info {
    my ($self, $group_type, $servers) = @_;

    my $webapi_config     = $self->webapi_config;
    my @exclusive_servers = ('p01_ts01');
    my $app_config        = BOM::Config::Runtime->instance->app_config->system->mt5;
    my @response;

    foreach my $server (@$servers) {
        push @response, {
            disabled           => ($app_config->suspend->all || $app_config->suspend->$group_type->$server->all) ? 1 : 0,
            environment        => $webapi_config->{$group_type}{$server}{environment},
            geolocation        => $webapi_config->{$group_type}{$server}{geolocation},
            id                 => $server,
            recommended        => $servers->[0] eq $server                   ? 1 : 0,    # server list is sorted by priority
            supported_accounts => (any { $_ eq $server } @exclusive_servers) ? ['gaming', 'financial', 'financial_stp'] : ['gaming'],
        };
    }

    return [
        sort {
                   $b->{recommended} cmp $a->{recommended}
                or $a->{geolocation}{region} cmp $b->{geolocation}{region}
                or $a->{geolocation}{sequence} cmp $b->{geolocation}{sequence}
        } @response
    ];
}

=head2 servers

    $obj->servers()

Get the list of servers supported, filtered to type if provided

=cut

sub servers {
    my $self = shift;

    my $mt5_config = $self->webapi_config();
    return undef unless $mt5_config;

    my @servers = ();

    foreach my $group_type (sort keys %$mt5_config) {
        next if $self->{group_type} and $self->{group_type} ne $group_type;
        next if $group_type eq 'request_timeout';

        foreach my $server_type (sort keys %{$mt5_config->{$group_type}}) {
            push @servers,
                create_server_structure(
                server_type => $server_type,
                server      => $mt5_config->{$group_type}{$server_type},
                );
        }
    }

    return \@servers;
}

=head2 create_server_structure

    create_server_structure(server_type => 'p01_ts01', server => $server_hash)

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

    return undef unless $args{server_type} and $args{server};

    return {
        $args{server_type} => {
            geolocation => {
                location => $args{server}->{geolocation}{location},
                region   => $args{server}->{geolocation}{region},
                sequence => $args{server}->{geolocation}{sequence},
            },
            environment => $args{server}->{environment},
        },
    };
}

=head2 routing_config

Returns the whole routing config by country

=cut

sub routing_config {
    my $routing_config = BOM::Config::mt5_server_routing();

    die "Cannot load mt5 routing config." unless $routing_config;

    return $routing_config;
}

=head2 webapi_config

Returns the whole server webapi_config

=cut

sub webapi_config {
    my $mt5_webapi_config = BOM::Config::mt5_webapi_config();

    die "Cannot load mt5 webapi config." unless $mt5_webapi_config;

    return $mt5_webapi_config;
}

=head2 groups_config

Return the whole groups config

=cut

sub groups_config {
    my $groups_config = BOM::Config::mt5_account_types();

    die "Cannot load mt5 webapi config." unless $groups_config;

    return $groups_config;
}

=head2 symmetrical_servers

    $obj->symmetrical_servers()

Return all the servers within the same region of the instance, including the instance.

Europe region is exception. There would be no symmetrical server for p01_ts01 (Irland) for load-balance purposes

=cut 

sub symmetrical_servers {
    my $self = shift;

    my %servers   = ();
    my $config    = $self->webapi_config->{$self->{group_type}};
    my $exception = 'p01_ts01';

    return {$exception => $config->{$exception}} if $self->{server_type} eq $exception;

    foreach my $srv (keys %$config) {
        $servers{$srv} = $config->{$srv}
            if defined $srv
            and $srv ne $exception
            and $config->{$srv}{geolocation}{region} eq $config->{$self->{server_type}}{geolocation}{region};
    }

    return \%servers;
}

1;
