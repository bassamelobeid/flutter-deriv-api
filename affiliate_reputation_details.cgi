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

my $is_compliance = BOM::Backoffice::Auth::has_authorisation(['Compliance']);

if (exists $input{reputation_check} && $is_compliance) {
    try {
        $user->update_reputation_status(
            reputation_check        => $input{reputation_check}        // '',
            reputation_check_status => $input{reputation_check_status} // '',
            reputation_check_type   => $input{reputation_check_type}   // '',
            social_media_check      => $input{social_media_check}      // '',
            company_owned           => $input{company_owned}           // '',
            criminal_record         => $input{criminal_record}         // '',
            civil_case_record       => $input{civil_case_record}       // '',
            fraud_scam              => $input{fraud_scam}              // '',
            start_date              => $input{start_date}              // '',
            last_review_date        => $input{last_review_date}        // '',
            reference               => $input{reference}               // ''
        );

        if ($input{reputation_check_status} eq "Failed") {
            $client->status->setnx('disabled', BOM::Backoffice::Auth::get_staffname(), 'Account should be disable due to Failed Repuation check.');
            $is_affiliate = 0;
        } else {
            $client->status->_clear('disabled');
            $is_affiliate = 1;
        }
        print "<p class=\"notify\">Successfully updated for client: $loginid</p>";
    } catch ($e) {
        print "<p class=\"notify notify--warning\">Failed to update Reputation status of affiliate: $loginid => $e</p>";
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
    reputation_check        => $user_reputation_status->{reputation_check}        // '',
    reputation_check_status => $user_reputation_status->{reputation_check_status} // '',
    reputation_check_type   => $user_reputation_status->{reputation_check_type}   // '',
    social_media_check      => $user_reputation_status->{social_media_check}      // '',
    company_owned           => $user_reputation_status->{company_owned}           // '',
    criminal_record         => $user_reputation_status->{criminal_record}         // '',
    civil_case_record       => $user_reputation_status->{civil_case_record}       // '',
    fraud_scam              => $user_reputation_status->{fraud_scam}              // '',
    start_date              => $start_date                                        // '',
    last_review_date        => $last_review_date                                  // '',
    reference               => $user_reputation_status->{reference}               // '',
    is_compliance           => $is_compliance                                     // '',
};

print q{
<script type="text/javascript" language="javascript">
$(document).ready(function() {
      $('.datepick').datepicker({dateFormat: "yy-mm-dd"});
});
</script>
};

BOM::Backoffice::Request::template()->process('backoffice/affiliate_reputation_details.html.tt', $template_params);
