#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;

use BOM::Backoffice::Sysinit ();
use f_brokerincludeall;
use BOM::Database::AutoGenerated::Rose::Audit::Client::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::ClientStatus::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::ClientPromoCode::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::ClientAuthenticationMethod::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::ClientAuthenticationDocument::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::PaymentAgent::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::FinancialAssessment::Manager;
use BOM::Database::AutoGenerated::Rose::Audit::SelfExclusion::Manager;
use BOM::Backoffice::Request qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("SHOW AUDIT TRAIL");

my $broker = request()->broker_code;

if ($broker eq 'FOG') {
    print "NOT RELEVANT FOR BROKER CODE FOG";
    code_exit_BO();
}

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
    })->db;

my $category = encode_entities(request()->param('category') // "");
my $loginid  = encode_entities(request()->param('loginid')  // "");
my $page     = request()->param('page')     || 0;
my $pagesize = request()->param('pagesize') || 40;
my $offset   = $page * $pagesize;
my @system_cols = qw/stamp staff_name operation remote_addr/;
my @noshow_cols = qw/pg_userid client_port id client_addr client_loginid document_format/;

my $myself_args = {
    broker   => $broker,
    category => $category
};
my $return_args = {broker => $broker};
my ($title_bar, $return_cgi);
my $page_1 = $page + 1;
if ($loginid) {
    $title_bar              = "Audit Trail ($category) on Client ($loginid) - Page ($page_1)";
    $myself_args->{loginid} = $loginid;
    $return_args->{loginID} = $loginid;
    $return_cgi             = 'f_clientloginid_edit.cgi';
} else {
    $title_bar  = "Audit Trail ($category) on Broker ($broker) - Page ($page_1)";
    $return_cgi = 'f_clientloginid.cgi';
}

my @tables;
for ($category) {
    if (/^client_status_(\w+)/) {
        my $status_code = $1;
        if (Client::Account->client_status_types->{$status_code}) {
            @tables = ({
                    tabname => 'client_status',
                    MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::ClientStatus::Manager',
                    query   => [
                        status_code    => $status_code,
                        client_loginid => {like => "$broker%"}
                    ],
                });
        }
    } elsif (/^client_details$/) {
        @tables = ({
                tabname => 'client',
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::Client::Manager',
                query   => [loginid => $loginid],
            },
            {
                tabname => 'client_promo_code',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::ClientPromoCode::Manager',
            },
            {
                tabname => 'client_authentication_method',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::ClientAuthenticationMethod::Manager',
            },
            {
                tabname => 'client_authentication_document',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::ClientAuthenticationDocument::Manager',
            },
            {
                tabname => 'client_status',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::ClientStatus::Manager',
            },
            {
                tabname => 'financial_assessment',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::FinancialAssessment::Manager',
            },
            {
                tabname => 'self_exclusion',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::SelfExclusion::Manager',
            },
        );
    } elsif (/^payment_agent$/) {
        @tables = ({
                tabname => 'payment_agent',
                query   => [client_loginid => $loginid],
                MGR     => 'BOM::Database::AutoGenerated::Rose::Audit::PaymentAgent::Manager',
            },
        );
    }
}
unless (@tables) {
    print "Unsupported audit-trail category [" . $category . "]";
    code_exit_BO();
}

my (@logs, %hdrs, $hitcount);

for my $table (@tables) {
    my $tabname   = $table->{tabname};
    my $query     = $table->{query};
    my $MGR       = $table->{MGR};
    my $hits_call = "get_${tabname}_count";
    my $rows_call = "get_${tabname}";
    $hitcount = $MGR->$hits_call(
        query => $query,
        db    => $db
    ) || next;
    my $rows = $MGR->$rows_call(
        query   => $query,
        db      => $db,
        sort_by => 'stamp',
        (
            $loginid
            ? ()
            : (
                limit  => $pagesize,
                offset => $offset
            )
        ),
    );
    next unless @$rows;
    # accumulate new non-system column names into %hdrs
    my %cols = map { $_->name => 1 } $rows->[0]->meta->columns;
    delete $cols{$_} for (@system_cols, @noshow_cols);
    $hdrs{$_} = 1 for keys %cols;
    # now pre-process 'rows' to build 'log' entry (and flag changed cells, for individual users only)
    my $prevrow;
    for my $row (@$rows) {
        my $changes = {};
        my $data = {table => $tabname};
        for my $col (@system_cols) {
            $data->{$col} = $row->$col if $row->can($col);
        }
        if ($tabname eq 'client') {
            # as set by audit.set_staff..
            $data->{staff_name} = $row->pg_userid;
        } else {
            # this is because some code just puts 'system' into staff_name,
            # but other code goes to trouble of putting meaningful data there.
            # Better show both, if they are different and useful.
            for ($row->pg_userid) {
                next if /write|\?/;
                $data->{staff_name} ||= $_;
                next if $_ eq $data->{staff_name};
                $data->{staff_name} .= "/$_";
            }
        }
        for my $col (keys %cols) {
            $data->{$col} = $row->$col;
            if ($loginid && $prevrow) {
                $changes->{$col} = 1
                    if ($row->$col || '') ne ($prevrow->$col || '');
            }
        }
        $prevrow = $row;
        push @logs,
            {
            data    => $data,
            changes => $changes
            };
    }
}

my ($rowcount, $pages);
if ($loginid) {    # don't page for single login report
    $rowcount = scalar(@logs);
    $pages    = 1;
} else {
    $rowcount = $hitcount || 0;
    $pages = int($rowcount / $pagesize);
    $pages += 1 if $rowcount % $pagesize;
}

my @allhdrs;

if (@logs) {
    @allhdrs = (@system_cols, 'table', @{_sort_headers(\%hdrs)});
} else {
    @allhdrs = ('no data found');
}

my $logs = [sort { $a->{data}->{stamp} cmp $b->{data}->{stamp} } @logs];
my $stash = {
    hdrs     => \@allhdrs,
    logs     => $logs,
    rowcount => $rowcount,
    pages    => $pages,
    next     => $page < $pages ? $page + 1 : $page,
    prev     => $page > 0 ? $page - 1 : $page,
    pagesize => $pagesize,
    url_to_myself => request()->url_for("backoffice/show_audit_trail.cgi", $myself_args),
    url_to_client => request()->url_for("backoffice/$return_cgi",          $return_args),
    hidden_cols => {map { $_ => 1 } (qw/client_password secret_answer secret_question date_joined document_path/)},
};

Bar($title_bar);

BOM::Backoffice::Request::template->process('backoffice/show_audit_trail.html.tt', $stash) || die BOM::Backoffice::Request::template->error();

code_exit_BO();

sub _sort_headers {
    my $h             = shift;
    my $counter_end   = 200;
    my $counter_begin = -200;
    $h->{$_} = $counter_end++
        for (
        qw/address_city address_line_1 address_line_2 address_postcode address_state allow_copiers allow_login allow_omnibus broker_code cashier_setting_password checked_affiliate_exposures citizen client_password/
        );
    $h->{$_} = $counter_begin++
        for (qw/reason status_code document_type expiration_date comments payment_agent_withdrawal_expiration_date first_name last_name/);
    return [sort { $h->{$a} <=> $h->{$b} || $a cmp $b } keys %$h];
}
