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

use BOM::Test::WebsocketAPI::Parameters;

our $rpc_response;
our $requests;
our $publish_data;
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

Returns the requests generated from test params

=cut

sub requests {
    my (%args) = @_;

    my $filter = $args{filter} // sub { 1 };
    my $calls = $args{calls} // [grep { $_ !~ /authorize/ } keys $requests->%*];

    my @requests;
    for my $call ($calls->@*) {
        my @filtered_requests =
            map {
            { $call => $_->{$call} }
            }
            grep {
            $filter->($_)
            } $requests->{$call}->@*;
        push @requests, @filtered_requests;
    }

    return \@requests;
}

1;
