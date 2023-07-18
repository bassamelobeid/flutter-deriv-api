#!/etc/rmg/bin/perl
package main;

=pod

=head1 DESCRIPTION

This script retrieves affiliate details by client loginid and displays them as a table.
It will also indicate whether or not the client is not an affiliate.

=cut

use strict;
use warnings;

use List::Util qw(first);

use BOM::MyAffiliates;
use BOM::User::Client;
use BOM::Backoffice::Request qw(request);
use Syntax::Keyword::Try;

use BOM::Backoffice::PlackHelpers qw( PrintContentType );
BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("AFFILIATE REPUTATION DETAILS");

my %input   = %{request()->params};
my $loginid = $input{loginID};

my $url       = 'backoffice/affiliate_reputation_details.cgi';
my $self_post = request()->url_for($url);

unless ($loginid) {
    code_exit_BO(
        qq[<p>Login ID is required</p>
        <form action="$self_post" method="get">
        <label>Login ID:</label><input type="text" name="loginID" size="15" data-lpignore="true" />
        </form>]
    );
}

my $user          = BOM::User->new(loginid => $loginid) || die "Cannot find user for: $loginid";
my $client        = BOM::User::Client->new({loginid => $loginid});
my $my_affiliates = BOM::MyAffiliates->new();

my @affiliates;
my $is_affiliate = 1;

for my $sibling ($client->user->clients) {
    my $res = $my_affiliates->get_users(
        VARIABLE_NAME  => 'affiliates_client_loginid',
        VARIABLE_VALUE => $sibling->loginid
    );
    my @result =
          ref $res->{USER} eq 'ARRAY' ? @{$res->{USER}}
        : $res->{USER}                ? ($res->{USER})
        :                               ();
    push @affiliates, @result;
}

unless (@affiliates) {
    $is_affiliate = 0;
}

my $is_compliance = BOM::Backoffice::Auth0::has_authorisation(['Compliance']);

if (exists $input{affiliate_reason_for_reputation} && $is_compliance) {
    try {
        $user->update_reputation_status(
            reputation_status => $input{status_for_reputation}           // '',
            check_reason      => $input{affiliate_reason_for_reputation} // '',
            start_date        => $input{start_date}                      // '',
            last_review_date  => $input{last_review_date}                // '',
            comment           => $input{affiliate_notes}                 // ''
        );

        if ($input{status_for_reputation} eq "Failed") {
            $client->status->setnx('disabled', BOM::Backoffice::Auth0::get_staffname(), 'Account should be disable due to Failed Repuation check.');
            $is_affiliate = 0;
        } else {
            $client->status->_clear('disabled');
            $is_affiliate = 1;
        }
        print "<p class=\"notify\">Successfully updated for client: $loginid</p>";
    } catch ($e) {
        print "<p class=\"notify notify--warning\">Failed to update Reputation status of affiliate: $loginid</p>";
    }
}

unless ($is_affiliate) {
    print "<p class=\"notify notify--warning\">Client isn\'t an affiliate: $loginid</p>";
}

my $user_reputation_status = $user->get_reputation_status();
my $start_date             = $user_reputation_status->{start_date};
my $last_review_date       = $user_reputation_status->{last_review_date};
$start_date       = Date::Utility->new($start_date)->date       if $start_date;
$last_review_date = Date::Utility->new($last_review_date)->date if $last_review_date;

my $template_params = {
    user_affiliate_reputation_status => $user_reputation_status->{reputation_status} // '',
    user_affiliate_check_reason      => $user_reputation_status->{check_reason}      // '',
    user_affiliate_start_date        => $start_date                                  // '',
    user_affiliate_last_review_date  => $last_review_date                            // '',
    user_affiliate_comment           => $user_reputation_status->{comment}           // '',
    is_compliance                    => $is_compliance                               // '',
};

print q{
<script type="text/javascript" language="javascript">
$(document).ready(function() {
      $('.datepick').datepicker({dateFormat: "yy-mm-dd"});
});
</script>
};

BOM::Backoffice::Request::template()->process('backoffice/affiliate_reputation_details.html.tt', $template_params);
