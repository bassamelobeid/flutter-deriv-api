package BOM::Test::APITester::Tests::ProposalOpenContract;

no indirect;

use strict;
use warnings;

use Future::Utils qw(fmap_void);
use Devops::BinaryAPI::Tester::DSL;

=head2 buy_then_sell_contract

Buy contracts with subscribe, 
wait for proposal open contracts streams
and then sell the contracts

=over 4

=item * C<$suite>

=item * C<%args> - Subscription arguments

%args contains the following keys: 
    C<token> : client token to make connection 
    C<requests> : array ref of subscription (buy) requests
    C<concurrent> : Maximum number of buy requests to be subscribed concurrently 

=back

=cut

suite buy_then_sell_contract => sub {
    my ($suite, %args) = @_;
    
    my $context = $suite->last_context;
    
    #Filter out requests except `buy` since this suite only targets buy requests 
    my @buy_requests = grep { (keys($_->%*))[0] eq 'buy' } $args{requests}->@*; 
    
    fmap_void {
        my ($method, $request) = $_->%*;
        
        $context
        ->connection(token => $args{token})
        ->subscribe(buy => $request)
        ->take_until(sub {
            shift->{body}->{is_sold}
        })
        ->expect_done(sub {
            my $buy_response = shift;
            my $sell_response = pop;
            my @poc_reponses = @_;
            
            # Check buy response
            ok ($buy_response->{body}->{contract_id}, "Contract '" . 
            $buy_response->{body}->{longcode} . 
            "' is purchased at buy price " . 
            $sell_response->{body}->{buy_price});

            # Check proposal_open_contract response
            ok ($_->{body}->{is_sold} == 0)  for (@poc_reponses);
            
            # Check sell response
            ok ($sell_response->{body}->{is_sold} == 1, 
            "Contract '" . $sell_response->{body}->{longcode} . 
            "' is sold at bid price: " . 
            $sell_response->{body}->{bid_price});
            
        })
        ->timeout_ok(5, sub {
            shift->take_latest
        }, 'There should be no more poc response after selling the contract')
        ->completed

    } foreach => [ @buy_requests ], %args{qw(concurrent)}
};

1;
