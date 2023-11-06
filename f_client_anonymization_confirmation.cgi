#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;
use POSIX;
use f_brokerincludeall;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Syntax::Keyword::Try;
use List::Util qw(min);

use constant PAGE_SIZE => 50;

BOM::Backoffice::Sysinit::init();
PrintContentType();
BrokerPresentation("ANONYMIZATION CONFIRMATION");

my $request_params      = request()->params;
my $confirmation_status = $request_params->{status} // 'all';
my $loginid_pattern     = quotemeta($request_params->{loginid_pattern} // '');
my $page_number         = $request_params->{page_number} // 1;

my $collector_db = BOM::Database::ClientDB->new({
        broker_code => 'FOG',
        operation   => 'collector',
    })->db->dbic;

my $confirmation_index = $request_params->{"save_confirmation"};
if (defined $confirmation_index) {
    my $user_id = $request_params->{"user_id_$confirmation_index"};
    my $status  = $request_params->{"status_$confirmation_index"};
    my $reason  = $request_params->{"reason_$confirmation_index"};

    $collector_db->run(
        fixup => sub {
            return $_->selectall_array(
                "SELECT * FROM users.set_anonymization_confirmation_status(?,?,?,?)",
                {Slice => {}},
                $user_id + 0,
                $status, $reason, BOM::Backoffice::Auth::get_staffname());
        }) if defined($user_id) && $status;
}

# render the search box
Bar('Filter Candidates');

$page_number = 1 if $request_params->{search_button};
my $status_selected = {map { $_ => ($confirmation_status eq $_ ? 'selected' : '') } qw/all pending approved postponed/};
my $search_action   = request()->url_for('backoffice/f_client_anonymization_confirmation.cgi');

BOM::Backoffice::Request::template()->process(
    'backoffice/anonymization_search.html.tt',
    {
        search_action   => request()->url_for('backoffice/f_client_anonymization_confirmation.cgi'),
        status_selected => $status_selected,
        loginid_pattern => $loginid_pattern,
    },
) || die BOM::Backoffice::Request::template()->error(), "\n";

# render the candidate list
Bar('Candidate List');

my ($row_count) = $collector_db->run(
    fixup => sub {
        return $_->selectrow_array('SELECT count(*) FROM users.get_anonymization_candidates(?,?, TRUE)', undef, $loginid_pattern, 'pending');
    });

if ($row_count) {
    my $page_count = ceil($row_count / PAGE_SIZE);
    $page_number = $page_count if $page_number > $page_count;

    my $offset = ($page_number - 1) * PAGE_SIZE;

    my @clients = $collector_db->run(
        fixup => sub {
            return $_->selectall_array(
                "SELECT * FROM users.get_anonymization_candidates(?,?, TRUE, ?, ?)",
                {Slice => {}},
                $loginid_pattern, ($confirmation_status eq 'all' ? undef : $confirmation_status),
                PAGE_SIZE, $offset
            );
        });

    $_->{loginids} = [split(' ', $_->{loginids})] for @clients;

    BOM::Backoffice::Request::template()->process(
        'backoffice/anonymization_confirmation.html.tt',
        {
            clients     => \@clients,
            page_number => $page_number,
            page_count  => $page_count,
            self_url    => request()->url_for(
                'backoffice/f_client_anonymization_confirmation.cgi',
                {
                    confirmation_status => $confirmation_status,
                    loginid_pattern     => $loginid_pattern
                }
            ),
            client_url => request()->url_for('backoffice/f_clientloginid_edit.cgi'),
        },
    ) || die BOM::Backoffice::Request::template()->error(), "\n";
} else {
    print('<div class="notify notify--warning">No client found</div>');
}

code_exit_BO();
