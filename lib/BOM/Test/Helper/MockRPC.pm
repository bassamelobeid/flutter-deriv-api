package BOM::Test::Helper::MockRPC;

use strict;
use warnings;
use Moo;
use Exporter qw( import );
our @EXPORT_OK = qw(mock_call_rpc);
use Test::MockModule;
use Clone qw (clone);
use Struct::Dumb;

struct Tmp => [qw(result)];

=head1 MockRPC

MockRPC Mocks call_rpc to allow websocket testing with out using RPC.


=head1 SYNOPSIS
    
    use BOM::Test::Helper::MockRPC;
    my $dummy_result = {13=>{send_ask{{ask_price => 10, payout => 13.50 }, 23=>{send_ask{ask_price =>5, payout =>32}}};
    my $mock_rpc = BOM::Test::Helper::MockRPC->new(mocked_methods=>{'send_ask' => $result });
    $mock_rpc->start;

=head1 DESCRIPTION

This module is intended to allow mocking of  Mojo::WebSocketProxy::Backend::JSONRPC::call_rpc.  You pass it dummy results to return and
the name(s) of the calls/methods you would like to have replaced. By default it will not mock any calls. 
the dummy results are preceded by a number that links the response to the request. 
The  dummy results can be built from the requests using the methods in  C<BOM::Test::Helper::MockRPC::SendAsk>
the request needs to have a matching pass through attribute called "mock_rpc_request" that matches the result  you wish to have returned. 

        passthrough => { mock_rpc_request_id => 2 },

In order to see what might be used as a valid Dummy response you can dump the results in the original subroutine while 
using the API

=cut

has mocked_methods => (is => 'rw');

=head2 start

Starts the Mocking of call_rpc 
Takes the following arguments as named parameters

=over 4

=item self

=back

Returns undef

=cut

sub start {
    my ($self) = @_;
    my $mock_rpc = Test::MockModule->new('Mojo::WebSocketProxy::Backend::JSONRPC');
    my $call_rpc_mock;
    #Don't conflict with $self in call_rpc_mock  sub.
    my $all_mocked_results = $self->mocked_methods;

    #This is a barstardised copy of Mojo::WebSocketProxy::Backend::JSONRPC::call_rpc.
    #it attempts to implement everything from that subroutine that matters to tests
    #excluding the actual call to RPC backend which we are mocking.
    $call_rpc_mock = sub {
        my ($self, $c, $req_storage) = @_;
        my $method = $req_storage->{method};
        my $mocked_results;
        #Note that $all_mocked_results is from the parent sub but all other variables are created when call_rpc is called.
        if (exists $req_storage->{args}->{passthrough}->{mock_rpc_request_id}) {
            $mocked_results = $all_mocked_results->{$req_storage->{args}->{passthrough}->{mock_rpc_request_id}};
        }
        my @mocked_method_names = keys(%$mocked_results);
        if (grep { $_ ne $method } @mocked_method_names) {
            return $mock_rpc->original("call_rpc")->(@_);
        }

        $req_storage->{call_params} ||= {};

        my $rpc_response_cb = $self->get_rpc_response_cb($c, $req_storage);

        my $before_get_rpc_response_hook = delete($req_storage->{before_get_rpc_response}) || [];
        my $after_got_rpc_response_hook  = delete($req_storage->{after_got_rpc_response})  || [];
        my $before_call_hook             = delete($req_storage->{before_call})             || [];

        $_->($c, $req_storage) for @$before_call_hook, @$before_get_rpc_response_hook;

        my $dummy_result = clone($mocked_results->{$method});

        #hooks are expecting an object so convert dummy_result to one here
        my $res_object = Tmp($dummy_result);

        $_->($c, $req_storage, $res_object) for @$after_got_rpc_response_hook;
        my $api_response = $rpc_response_cb->($dummy_result);
        $c->send({json => $api_response}, $req_storage);
        return;

    };
    $mock_rpc->mock('call_rpc', $call_rpc_mock);
    return undef;
}

1;
