package BOM::Test::WebsocketAPI::Template::DSL;

no indirect;
use warnings;
use strict;

=head1 NAME

BOM::Test::WebsocketAPI::Template::DSL - Helper class for data template with interpolation

=head1 SYNOPSIS

    use BOM::Test::WebsocketAPI::Template::DSL;

    # Predefines proposal requests to send to the API based on params
    request proposal => sub {
        # $_->name is the name of the requested params
        symbol   => $_->underlying->symbol,
        currency => $_->currency,
        ...
    }, qw(currency underlying);

    # Proposal requests to match with the requests received by RPC
    rpc_request send_ask => sub {
        country  => $_->country,
        currency => $_->currency,
        symbol   => $_->underlying->symbol,
        ...
    }, qw(currency country underlying);

    # Respective responses for each RPC request
    rpc_response send_ask => sub {
        country  => $_->country,
        currency => $_->currency,
        symbol   => $_->underlying->symbol,
        ...
    };

    # Data to publish to Redis and receive in API
    publish proposal => sub {
        country  => $_->country,
        currency => $_->currency,
        symbol   => $_->underlying->symbol,
        extra    => $_->extra,
        ...
    }, qw(extra);

=head1 DESCRIPTION

This module is a helper class for static mock data, and gives them the ability to
generated version of their data.

=cut

use Exporter;
our @ISA    = qw( Exporter );
our @EXPORT = qw( request rpc_request rpc_response publish );    ## no critic (Modules::ProhibitAutomaticExportation)

use BOM::Test::WebsocketAPI::Parameters qw( expand_params );

# Keeps the serialized rpc_request keys to params mapping
our $rpc_requests;
# Params used to generate publish data, added dynamically by rpc responses.
our $publish_params;
# Used for finding the handler module for given RPC request.
our $rpc_req_to_module;
# Used for finding the publish callbacks provided by a module and given a type.
our $module_to_publish_cb;
# RPC response callbacks registered per module
our $rpc_response_cb;

=head2 request

Registers and auto generates requests to send to the API, given some C<@params>.

=cut

sub request {
    my ($type, $template, @params) = @_;

    my $requests = $BOM::Test::WebsocketAPI::Data::requests //= {};
    push $requests->{$type}->@*, map {
        { $type => {$template->()->%*}, params => $_ }
    } expand_params(@params);

    return undef;
}

=head2 rpc_request

Registers and auto generates requests to match against RPC requests, given
C<@params>, the same C<@params> will be passed to C<publish> and C<rpc_response>.

=cut

sub rpc_request {
    my ($type, $template, @params) = @_;

    my ($module) = caller;

    for (expand_params(@params)) {
        # We only need the mapping between the requests pass to RPC to params
        # that generated them.
        my $req_key = req_key($template->());
        $rpc_req_to_module->{$req_key} = $module;
        $rpc_requests->{$req_key}      = $_;
    }
    return undef;
}

=head2 rpc_response

RPC response to be generated based on the received C<$rpc_request>, the sub
receives the same C<@params> as the ones used to generate C<rpc_request>.

=cut

sub rpc_response {
    my ($type, $template) = @_;

    my ($module) = caller;
    $rpc_response_cb->{$module} = $template;

    return undef;
}

=head2 publish

Publish data to send to Redis, accepts extra C<@params>, receives those and
parameters that C<rpc_request> was called with.

=cut

sub publish {
    my ($type, $template) = @_;

    my $publish_methods = $BOM::Test::WebsocketAPI::Data::publish_methods //= {};
    $publish_methods->{$type} = 1;

    my ($module) = caller;
    $module_to_publish_cb->{$module}{$type} = $template;

    return undef;
}

=head2 key

Takes an object and recursively turns it to a unique string, sorts hash keys to
return a consistent response.

=cut

sub key {
    my ($obj) = @_;

    return join '_', map { key($_) // 'undef' } $obj->@* if ref($obj) eq 'ARRAY';

    return join '_', map { $_ => key($obj->{$_}) // 'undef' } sort keys $obj->%* if ref($obj) eq 'HASH';

    return $obj;
}

=head2 wrap_rpc_response

Takes a hash and turns it to an acceptable RPC response.

=cut

sub wrap_rpc_response {
    my ($request, $response) = @_;

    return bless({
            'rpc_response' => {
                'jsonrpc' => '2.0',
                'result'  => {$response->%*},
                'id'      => $request->{id}}
        },
        'MojoX::JSON::RPC::Client::ReturnObject'
    );
}

=head2 req_key

Generates a unique key for a given request object. This makes it easier to find
objects using their contents.

=cut

sub req_key {
    my ($request) = @_;

    $request = $request->{params} if exists $request->{params};

    # longcode has its args in short_codes :'(
    return key({$request->%{qw(short_codes)}}) if exists $request->{short_codes};

    # transaction has its shortcode out of the args
    return key({$request->%{qw(shortcode)}}) if exists $request->{args} and exists $request->{args}{shortcode};

    my $req = $request->{args} // $request // die 'Invalid RPC request';

    # Shallow clone
    $req = {$req->%*};

    delete $req->{req_id};
    delete $req->{subscribe};
    delete $req->{passthrough};

    return key($req);
}

=head2 rpc_response

Returns generated RPC response based on parameters saved by C<rpc_request> call.
Basically we make a key from the request received from Mock RPC and look up that
key to find the parameters to use to generate the RPC response.

This makes it easier to statically generate expected RPC requests and their RPC
responses.

=cut

$BOM::Test::WebsocketAPI::Data::rpc_response = sub {
    my ($request) = @_;

    my $req_key = req_key($request);

    my $module = $rpc_req_to_module->{$req_key};

    die "No params available for RPC request: $req_key" unless $module;

    # Scalar, but used for to set $_
    for ($rpc_requests->{$req_key}) {
        # This will dynamically pass the same params used to generate RPC response
        # to publishers, make it possible to publish only useful data.
        if (exists $module_to_publish_cb->{$module}) {
            $publish_params->{$module}{key($_)} = $_;
        }
        return wrap_rpc_response($request, $rpc_response_cb->{$module}->());
    }
};

=head2 publish_data

The publish data is generated by callbacks (C<templates>). To generate those data
we take the publish parameters, which can be predefined using C<publish> or can
be the parameters passed to RPC calls (which is populated with each Mock RPC call)

The returned value from a C<template> can be either a hash ref or an array ref.
If an array ref is passed, we loop through it and add those hash refs inside.

    package Buy;

    rpc_request buy => sub {
        # Generate RPC buy requests with $_->contract
    }, qw(contract);
    publish proposal_open_contract => sub {
        # Either of $_->contract or $_->client is available, not both
        # This behavior is useful if you want to start publishing different
        # values if an RPC call is made.
    }, qw(client);

=cut

# This sub is very ugly, but so is our pub/sub design
$BOM::Test::WebsocketAPI::Data::publish_data = sub {
    my ($requested_method) = @_;
    my $data;
    for my $module (keys $module_to_publish_cb->%*) {
        for my $method (keys $module_to_publish_cb->{$module}->%*) {
            # The requested_method can't be handled by this method
            next unless $method eq $requested_method;
            # There are no parameters received by RPC calls or predefined
            next unless exists $publish_params->{$module};
            for (values $publish_params->{$module}->%*) {
                # Pass the params to generate publish data
                my $to_publish = $module_to_publish_cb->{$module}{$method}->();
                # Ignore empty publish data
                next unless $to_publish;
                for my $payload (ref($to_publish) eq 'ARRAY' ? $to_publish->@* : $to_publish) {
                    my ($key, $value) = $payload->%*;
                    push $data->{$key}->@*, $value;
                }
            }
        }
    }
    return $data;
};

1;
