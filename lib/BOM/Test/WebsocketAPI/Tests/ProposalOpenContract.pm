package BOM::Test::APITester::Tests::ProposalOpenContract;

no indirect;

use strict;
use warnings;

use List::Util;
use Future::Utils qw(fmap_void);
use Devops::BinaryAPI::Tester::DSL;
use List::Util qw(first);

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
        ->take_until(sub {
            my $response = shift;
            $response->isa('Binary::API::OpenContract') && $response->is_sold;
        })
        ->expect_done(sub {
            my @all_reposonses = @_;
            my $buy_response = shift;
            my $sell_response = pop;
            my @poc_responses = @_;

            # Check buy response
            ok ($buy_response->contract_id, "Contract '" .
            $buy_response->longcode .
            "' is purchased at buy price " .
            $sell_response->buy_price);

            # Check proposal_open_contract response

            ok ($poc_responses[$_]->is_sold == 0, "poc response $_ is unsold") for (0..$#poc_responses);

            # Check sell response
            ok ($sell_response->is_sold == 1,
            "Contract '" . $sell_response->longcode .
            "' is sold at bid price: " .
            $sell_response->bid_price);
            
            # check subscription id
            my @subscriptions = grep { $_->envelope->subscription } @all_reposonses;
            is scalar(@subscriptions), scalar(@all_reposonses), 'All responses have subcription id';
            ok List::Util::all(sub { $buy_response->envelope->subscription->id eq $_->envelope->subscription->id; }, @subscriptions), 'Subscription ids are all the same';
        })
        ->timeout_ok(5, sub {
            shift->take_latest
        }, 'There should be no more poc response after selling the contract')
        ->completed

    } foreach => [ @buy_requests ], %args{qw(concurrent)}
};



suite poc_no_contract_id => sub {
    my ($suite, %args) = @_;

    # Get two buy reqs with differenct symbols
    my @filtred_reqs = grep { (keys($_->%*))[0] eq 'buy' } $args{requests}->@*;
    my @buy_reqs = ( $filtred_reqs[0] );
    $buy_reqs[1] = first { $_->{buy}{parameters}{symbol} ne $buy_reqs[0]->{buy}{parameters}{symbol} } @filtred_reqs;

    my %bought;

    my $con = $suite
    ->last_context
    ->connection(token => $args{token});

    $con
    ->subscribe(proposal_open_contract => 1)
    ->buy($buy_reqs[0]->{buy}->%*)
    ->take_until(sub {
        return 0 unless $_->contract_id;
    	push $bought{$_->is_sold // 0}->@*, $_->contract_id;
    	return 1 if exists $bought{1} and $bought{1}->@* == 2;
    	if ( $_->is_sold ) {
    	    note "1st contract sold, buying 2nd contract";
    	    # poc will wait for two contracts to sell, therefore we don't need to wait for this buy
    		$con
    		->buy($buy_reqs[1]->{buy}->%*)
    		->completed
    		->retain;
    	}
    	return 0;
    })
    ->expect_done(sub {
        for my $buy (0..1) {
           my $cnt = grep { $_->underlying && $_->underlying eq $buy_reqs[$buy]->{buy}{parameters}{symbol} } @_;
           cmp_ok $cnt, '>', 1, 'contract '.($buy+1)." got $cnt responses";
        }
    });

};

1;
