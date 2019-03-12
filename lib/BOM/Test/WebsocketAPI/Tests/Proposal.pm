package BOM::Test::APITester::Tests::Proposal;

no indirect;

use strict;
use warnings;

use Devops::BinaryAPI::Tester::DSL;

=head2 proposal_subscribe

Test a simple Subscription, You will need to have published proposal first

     $tester->publish(proposal => [\%proposal_request]); 
     $tester->proposal_subscribe(%proposal_request)->get;

=over 4

=item C<%args>  - hash of paramters that are required to subscribe to a proposal, same attributes you would use in the API playground. 


=back

    undef

=cut

suite proposal_subscribe => sub {
    my ($suite, %args) = @_;

    my $symbol = $args{symbol} // 'R_100';
    my $num = $args{num} // 5;
    my $method = $args{method} // 'proposal';
    my $default_proposal_request = {
        amount => 11,
        basis => "stake",
        contract_type => "PUT",
        currency => "USD",
        duration => 5,
        duration_unit => "h",
        proposal => 1,
        req_id => 16,
        subscribe => 1,
        symbol => "frxAUDJPY",
    };
    my $proposal_request = \%args // $default_proposal_request;
    $suite->connection
    ->subscribe($method, $proposal_request )
    ->take(5);

};



1;
