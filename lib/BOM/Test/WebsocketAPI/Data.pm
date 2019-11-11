package BOM::Test::WebsocketAPI::Data;

no indirect;
use warnings;
use strict;

=head1 NAME

BOM::Test::WebsocketAPI::Data - Stores data for mocking RPC and publishing to Redis

=head1 SYNOPSIS

    use BOM::Test::WebsocketAPI::Data qw( requests );

    my $requests = requests(
        calls => [qw(ticks_history proposal_array)],
        filter => sub {
            shift->{params}->underlying->symbol =~ /R_100/;
        },
    );

=head1 DESCRIPTION

This module keeps the request to response mapping, that's used to mock the
behavior of RPC servers and publishing data to Redis.

This module doesn't do much by itself, look at the C<BOM::Test::WebsocketAPI::Publisher>
and C<BOM::Test::WebsocketAPI::MockRPC> for further info.

=cut

use Exporter;
our @ISA       = qw( Exporter );
our @EXPORT_OK = qw( rpc_response publish_data publish_methods requests );

use BOM::Test::WebsocketAPI::Parameters qw( clients );

=head1 PACKAGE VARIABLES

All of the below package variables are populated in C<Template/DSL.pm>, they
are not meant to be accessed directly from outside (except for from
C<Template/DSL.pm>), name of these package variables are subject to change
and will break the code that's using them.

They each have their own accessors with the same name without the C<$> sigil:

    # Use this:
    #
    use BOM::Test::WebsocketAPI::Data qw( requests );

    # NOT this:
    #
    $BOM::Test::WebsocketAPI::Data::requests;

=cut

=head2 $rpc_response

A callback to get the response template based on an RPC request

=cut

our $rpc_response;

=head2 $requests

A hashref containing lists of predefined requests, per call. It's used to
send API requests that are recognized by the MockRPC, any unrecognized request
results in an error.

=cut

our $requests;

=head2 $publish_data

A callback to get publish values, it's called from Publisher every second to
get new publish data

=cut

our $publish_data;

=head2 $publish_methods

A list of available publish methods, Publisher uses this to know which methods
have publish data available.

=cut

our $publish_methods;

=head2 rpc_response

Returns all available mocked RPC response data based on the request

=cut

sub rpc_response {
    my ($request) = @_;

    return $rpc_response->($request);
}

=head2 publish_data

Returns the data to publish to Redis.

=cut

sub publish_data {
    my ($method) = @_;

    return $publish_data->($method);
}

=head2 publish_methods

Returns a list of methods to publish.

=cut

sub publish_methods { return keys $publish_methods->%* }

=head2 requests

Returns a list of all requests based on the C<filter>, C<calls> and C<client>.
C<filter> needs to return true to include a request, C<calls> includes all the
calls by default. C<client> is the first client returned by the C<clients> call
from the C<Parameters> module.

=cut

sub requests {
    my (%args) = @_;

    my $filter = $args{filter} // sub { 1 };
    my $calls  = $args{calls}  // [keys $requests->%*];
    my $client = $args{client} // clients()->[0];

    my @requests;
    for my $call ($calls->@*) {
        for my $req_item ($requests->{$call}->@*) {
            my $params     = $req_item->{params};
            my $req_client = $params->client;
            # If the client is not present in the params, it's most
            # likely present as part of another parameter.
            for my $param_type (qw(contract proposal_array)) {
                $req_client = $params->$param_type->client if $params->$param_type;
            }
            # Skip this request if it doesn't belong to the client
            # in this group.
            next if defined $req_client and $req_client ne $client;
            next unless $filter->($req_item);
            push @requests, {$req_item->{request} => $req_item->{payload}};
        }
    }
    return \@requests;
}

1;
