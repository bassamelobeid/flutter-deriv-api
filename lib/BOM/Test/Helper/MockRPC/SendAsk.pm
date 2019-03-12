package BOM::Test::Helper::MockRPC::SendAsk;
use strict;
use warnings;
use Clone;

=head1 NAME

BOM::Test::Helper::MockRPC::SendAsk - Module to build paramters  for using in C<BOM::Test::Helper::MockRPC>

=head1 SYNOPSIS

 my %proposal_request = 
     (
         amount => 10,
         basis => "stake",
         contract_type => "PUT",
         currency => "USD",
         duration => 5,
         duration_unit => "m",
         proposal => 1,
         req_id => 16,
         subscribe => 1,
         symbol => "frxAUDJPY",
     );
 $dummy_result = BOM::Test::Helper::MockRPC::SendAsk::generate_from_request(\%proposal_request);
 my $mock_rpc = BOM::Test::Helper::MockRPC->new(mocked_methods=>{'send_ask' => $dummy_result} );
 $mock_rpc->start;

=head1 DESCRIPTION

  Used to build a response for the MockRPC call used in websocket tests.  It probably doesn't cover all scenarios
  and should be extended as required. 

=cut

sub get_template {
    my %result_template = (
        ask_price     => undef,
        date_start    => undef,
        display_value => "537.10",
        id            => "35a7ca74-416a-20a4-f876-9d9125070fa9",
        'longcode'    => 'longcode',
        payout        => "1000",
        spot          => "78.942",
        spot_time     => undef,
        'stash'       => {
            'valid_source'          => '1003',
            'app_markup_percentage' => '0'
        },
        'contract_parameters' => {
            'proposal'       => 1,
            'product_type'   => 'basic',
            'staking_limits' => {
                'max' => 20000,
                'min' => '0.5'
            },
            'duration'              => undef,
            'currency'              => undef,
            'amount_type'           => undef,
            'underlying'            => undef,
            'bet_type'              => undef,
            'date_start'            => 0,
            'amount'                => undef,
            'base_commission'       => '0.035',
            'barrier'               => 'S0P',
            'deep_otm_threshold'    => '0.05',
            'app_markup_percentage' => 0,
            'subscribe'             => 1
        },
    );
    return \%result_template;
}

=head2 generate_from_request

    Takes a proposal request and builds a dummy RPC response from it. using defaults
    in $result_template.

=over 4

=item request HashRef containing the proposal you intend to subscribe to in the test. 

=back

Returns a HashRef that should be fed to C<BOM::Test::Helper::MockRPC> 

=cut

sub generate_from_request {
    my ($request_ref)     = @_;
    my %request           = %$request_ref;
    my $now               = time;
    my $result_return_ref = get_template();
    my %result_return     = %$result_return_ref;
    foreach my $key (keys($result_return{contract_parameters}->%*)) {
        $result_return{contract_parameters}->{$key} = $request{$key} if exists $request{$key};
    }

    $result_return{contract_parameters}->{underlying}  = $request{symbol};
    $result_return{contract_parameters}->{bet_type}    = $request{contract_type};
    $result_return{contract_parameters}->{amount_type} = $request{basis};
    $result_return{ask_price}                          = $request{amount};
    $result_return{date_start}                         = $now;
    $result_return{spot_time}                          = $now;

    return \%result_return;
}

=head2 generate_from_requests {

    Takes an arrayref of proposal requests and returns generated data for the dummy RPC requests, 
    The mapping of response to request is done by adding the passthrough parameter 
    
                            passthrough => { mock_rpc_request_id => 2 }

    where 2 is the id you defined for this mapping 

=over 4

=item  proposal_requests ArrayRef  of proposal requests as per https://developers.binary.com/api/#proposal


=back

Returns a nested hashref of dummy RPC responses 

       }       
         {12 => {send_ask =>{spot_time => .....}}, 
         {26 => {send_ask =>{spot_time => .....}}
       }



=cut

sub generate_from_requests {
    my ($requests) = @_;
    my $dummy_results;
    foreach my $request (@$requests) {
        die "request must have passthrough->{mock_rpc_request_id} defined" if !defined $request->{passthrough}->{mock_rpc_request_id};
        $dummy_results->{$request->{passthrough}->{mock_rpc_request_id}}->{send_ask} = generate_from_request($request);
    }
    return $dummy_results;
}
1;
