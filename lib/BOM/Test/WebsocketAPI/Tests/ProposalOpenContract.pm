package BOM::Test::APITester::Tests::ProposalOpenContract;

no indirect;

use strict;
use warnings;

use Future::Utils qw(fmap_void);
use Devops::BinaryAPI::Tester::DSL;
use List::Util qw(first);
use Future::AsyncAwait;

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

    # Filter out requests except `buy` since this suite only targets buy requests
    my @buy_requests = grep { (keys($_->%*))[0] eq 'buy' } $args{requests}->@*;

    fmap_void {
        my ($method, $request) = $_->%*;
        
        $context
        ->connection(token => $args{token})
        ->subscribe(buy => $request)
        ->take(3)
        ->chain(async sub { 
            my $context = shift;
            my @resps = await $context->completed;
            my $contract_id = $resps[0]->contract_id;
            return ( $contract_id, await $context->sell( sell => $contract_id, price => 0 )->completed );
        })
        ->expect_done(sub {
            my ( $contract_id, $resp ) = @_;
            ok (ref($resp) eq 'Binary::API::Sell' && $resp->contract_id == $contract_id, 'valid sell response');
        })
        ->take_until(sub { ref($_[0]) eq 'Binary::API::OpenContract' && $_[0]->is_sold })
        ->expect_done(sub { 
            my @all_resps = @_;
            my $buy_resp = shift;
            my @poc_resps = @_;
            my $sell_resp = $poc_resps[-1];
            my $contract_id = $buy_resp->contract_id;
            
            # check buy response
            ok ($contract_id, "Contract id $contract_id '" .
            $buy_resp->longcode .
            "' was purchased at buy price " .
            $buy_resp->buy_price);
            
            # check following responses
            ok (ref($poc_resps[$_]) eq 'Binary::API::OpenContract' && $poc_resps[$_]->contract_id == $contract_id, "poc response $_ is valid") for (1..$#poc_resps);
            ok ($sell_resp->is_sold == 1, "Contract '" . $sell_resp->longcode .
              "' was sold at bid price: " .  $sell_resp->bid_price );

            # check subscription ids on all responses
            my @subscriptions = grep { $_->envelope->subscription } @all_resps;
            is scalar(@subscriptions), scalar(@all_resps), 'All responses have subcription id';
            ok (List::Util::all(sub { $buy_resp->envelope->subscription->id eq $_->envelope->subscription->id; }, @subscriptions), 'Subscription ids are all the same');
        } )
        ->timeout_ok(5, sub { shift->take_latest }, 'There should be no more poc response after selling the contract')
        ->release
        ->completed
        
    } foreach => [ @buy_requests ], %args{qw(concurrent)}
};


# subscribes to poc with no contract id, buys a contract and sells it, buys a second contract and sells it

suite poc_no_contract_id => sub {
    my ($suite, %args) = @_;

    # Get two buy reqs with different symbols
    my @filtred_reqs = grep { (keys($_->%*))[0] eq 'buy' } $args{requests}->@*;
    my @buy_reqs = ( $filtred_reqs[0] );
    $buy_reqs[1] = first { $_->{buy}{parameters}{symbol} ne $buy_reqs[0]->{buy}{parameters}{symbol} } @filtred_reqs;

    my %contracts;

    my $con = $suite
    ->last_context
    ->connection(token => $args{token});
    
    $con
    ->subscribe(proposal_open_contract => 1)
    ->buy($buy_reqs[0]->{buy}->%*)
    ->take_until( sub {
        return unless $_->contract_id;
        $contracts{$_->contract_id}{$_->is_sold}++;
        for (keys %contracts) {
            if ( $contracts{$_}{0} >= 3 && !$contracts{$_}{1} ) {
                $con->sell( sell=>$_, price=>0 )->completed->retain;
                if ( scalar keys %contracts==1 ){
                    $con->buy($buy_reqs[1]->{buy}->%*)->completed->retain;
                }
            }
        }
        return 1 if ( scalar grep { exists $_->{1} } values %contracts ) == 2;
    })
    ->expect_done(sub {
        # expected responses:
        # 1. initial poc response
        # 2-3. first contract pricing
        # 5. first contract final result
        # 6-8. second contract pricing
        # 9. second contract final result
        ok (scalar @_ == 9, 'got 9 responses in total');
        ok (!$_[0]->contract_id, 'first response has no contract_id');
        for my $buy (0..1) {
           my @poc = grep { $_->underlying && $_->underlying eq $buy_reqs[$buy]->{buy}{parameters}{symbol} } @_;
           ok (List::Util::all( sub { !$_->is_sold }, @poc[0..2] ), 'first 3 responses for contract '.($buy+1).' are unsold');
           ok ($poc[3]->is_sold, 'last response for contract '.($buy+1).' is sold');
        }        
    })
    ->release
    ->completed;

};

1;
