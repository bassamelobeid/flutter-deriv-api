#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;
use HTML::Entities;
use BOM::User::Client;

use BOM::Backoffice::Sysinit ();
use f_brokerincludeall;
use BOM::Backoffice::Request      qw(request);
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use BOM::Database::UserDB;

BOM::Backoffice::Sysinit::init();

PrintContentType();
BrokerPresentation("SHOW AUDIT TRAIL");

my $broker = request()->broker_code;

if ($broker eq 'FOG') {
    code_exit_BO('NOT RELEVANT FOR BROKER CODE FOG');
}

my $db = BOM::Database::ClientDB->new({
        broker_code => $broker,
    })->db;

my $category    = encode_entities(request()->param('category') // "");
my $loginid     = encode_entities(request()->param('loginid')  // "");
my $page        = request()->param('page')     || 0;
my $pagesize    = request()->param('pagesize') || 40;
my $offset      = $page * $pagesize;
my @system_cols = qw/stamp staff_name operation remote_addr/;
my @noshow_cols = qw/client_port id client_addr client_loginid document_format tbl/;

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
        @tables = ({
            table  => 'client_status',
            query  => "status_code = ? and client_loginid like ?",
            params => [$status_code, "$broker%"],
        });
    } elsif (/^client_details$/) {
        my $authentication_documents_queries = authentication_documents_queries($loginid, $broker);
        my $user_db_queries                  = user_db_queries($loginid, $broker);
        my $edd_status_queries               = edd_status_queries($loginid, $broker);
        my $affiliate_queries                = affiliate_queries($loginid, $broker);
        my $social_responsibility_queries    = social_responsibility_queries($loginid, $broker);

        @tables = ({
                table  => 'client',
                query  => "loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'client_promo_code',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'client_authentication_method',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'client_status',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'financial_assessment',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'self_exclusion',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'account',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'client_comments',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            {
                table  => 'proof_of_ownership',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
            $authentication_documents_queries->@*,
            $user_db_queries->@*,
            $edd_status_queries->@*,
            $affiliate_queries->@*,
            $social_responsibility_queries->@*,
        );
    } elsif (/^payment_agent$/) {
        @tables = ({
                table  => 'payment_agent',
                query  => "client_loginid = ?",
                params => [$loginid],
            },
        );
    }
}

unless (@tables) {
    code_exit_BO("Unsupported audit-trail category [" . $category . "]");
}

my (@logs, %hdrs, $hitcount);

for my $table (@tables) {
    my $query_broker = $table->{broker} // $broker;
    my $tabname      = $table->{table};
    my $query        = $table->{query};
    my $database     = $db;

    if ($query_broker ne $broker) {
        if ($query_broker eq 'users') {
            $database = BOM::Database::UserDB::rose_db();
        } else {
            $database = BOM::Database::ClientDB->new({
                    broker_code => $query_broker,
                })->db;
        }
    }

    $hitcount = _get_table_count(%$table, db => $database) || next;

    my $rows = _get_table_rows(
        %$table,
        db => $database,
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
    my %cols = map { $_ => 1 } keys %{$rows->[0]};
    delete $cols{$_} for (@system_cols, @noshow_cols);
    $hdrs{$_} = 1 for keys %cols;

    # now pre-process 'rows' to build 'log' entry (and flag changed cells, for individual users only)
    my $prevrow;
    for my $row (@$rows) {

        my $changes = {};

        my $data = {
            table      => delete $row->{tbl} // $tabname,
            staff_name => $row->{pg_userid}};

        for my $col (qw/stamp operation remote_addr/) {
            $data->{$col} = $row->{$col} if exists $row->{$col};
        }

        for my $col (keys %cols) {
            $data->{$col} = $row->{$col};
            if ($loginid && $prevrow) {
                $changes->{$col} = 1
                    if ($row->{$col} || '') ne ($prevrow->{$col} || '');
            }
        }

        $prevrow = $row;
        push @logs, {
            data    => $data,
            changes => $changes,
            $row->{edd_status} ? (row_classname => 'edd_status') : ()    # we use .edd_status CSS class to hide this row on CS columns
        };
    }

}

my ($rowcount, $pages);

if ($loginid) {    # don't page for single login report

    $rowcount = scalar(@logs);
    $pages    = 1;

} else {

    $rowcount = $hitcount || 0;
    $pages    = int($rowcount / $pagesize);
    $pages += 1 if $rowcount % $pagesize;

}

my @allhdrs = ('no data found');
@allhdrs = (@system_cols, 'table', @{_sort_headers(\%hdrs, $myself_args->{category})}) if @logs;

my $logs = [sort { $b->{data}->{stamp} cmp $a->{data}->{stamp} } @logs];

my $stash = {
    hdrs          => \@allhdrs,
    logs          => $logs,
    rowcount      => $rowcount,
    pages         => $pages,
    next          => $page < $pages ? $page + 1 : $page,
    prev          => $page > 0      ? $page - 1 : $page,
    pagesize      => $pagesize,
    url_to_myself => request()->url_for("backoffice/show_audit_trail.cgi", $myself_args),
    url_to_client => request()->url_for("backoffice/$return_cgi",          $return_args)};

# These hidden fields are not needed in audit trail
unless ($myself_args->{category} eq 'payment_agent') {
    $stash->{hidden_cols} = {map { $_ => 1 } (qw/client_password secret_answer secret_question date_joined document_path/)};
}
Bar($title_bar);

BOM::Backoffice::Request::template()->process('backoffice/show_audit_trail.html.tt', $stash) || die BOM::Backoffice::Request::template()->error(),
    "\n";

code_exit_BO();

sub _sort_headers {
    my ($h, $category) = @_;

    if ($category ne 'payment_agent') {

        my $counter_end   = 200;
        my $counter_begin = -200;
        $h->{$_} = $counter_end++
            for (
            qw/address_city address_line_1 address_line_2 address_postcode address_state allow_copiers allow_login broker_code cashier_setting_password checked_affiliate_exposures citizen client_password/
            );
        $h->{$_} = $counter_begin++ for (qw/reason status_code document_type expiration_date status comments first_name last_name/);

    }

    return [sort { $h->{$a} <=> $h->{$b} || $a cmp $b } keys %$h];
}

# given table and condition, return the number of rows.
# it will be used to replace Rose::DB::Object's get_tablename_count function
sub _get_table_count {
    my %args   = @_;
    my $table  = "audit.$args{table}";
    my $query  = $args{query};
    my $sql    = "select count(*) from $table t1 where $query";
    my $params = $args{params};
    my $db     = $args{db};
    return $db->dbic->run(
        fixup => sub {
            my ($result) = $_->selectrow_array($sql, undef, @$params);
            return $result;
        });
}

# given table and condition, return the rows.
# it will be used to replace Rose::DB::Object's get_tablename_all function
sub _get_table_rows {
    my %args   = @_;
    my $table  = "audit.$args{table}";
    my $query  = $args{query};
    my $limit  = $args{limit};
    my $offset = $args{offset} // 0;
    my $select = $args{select} // '*';

    my $sql = "select $select from $table t1 where $query order by stamp ";
    $sql .= "limit $limit offset $offset" if $limit;
    my $params = $args{params};
    my $db     = $args{db};
    return $db->dbic->run(
        fixup => sub {
            return $_->selectall_arrayref($sql, {Slice => {}}, @$params);
        });
}

=head2 authentication_documents_queries

Gets the needed queries to hit the authentication document table for the audit trail.

Takes the following arguments:

=over 4

=item * C<$loginid> - The loginid of the current client.

=back

Returns an arrayref of  database queries.

=cut

sub authentication_documents_queries {
    my $loginid           = shift;
    my $broker_code       = shift;
    my $client            = BOM::User::Client->new({loginid => $loginid}) || die "Cannot find client: $loginid";
    my @siblings_loginids = $client->is_virtual ? $client->user->bom_virtual_loginid : $client->user->bom_real_loginids;
    my $broker_loginids   = {};
    my $queries           = [];

    # Create a bucket of loginids per broker code.

    for (@siblings_loginids) {
        my $sibling_broker = $_ =~ s/[0-9]*//gr;
        $broker_loginids->{$sibling_broker} //= [];
        push $broker_loginids->{$sibling_broker}->@*, $_;
    }

    # We need one query per broker code.

    for my $broker (keys $broker_loginids->%*) {
        my $siblings_where_in = join ',', map { '?' } $broker_loginids->{$broker}->@*;

        push $queries->@*,
            {
            table  => 'client_authentication_document',
            query  => "client_loginid IN ($siblings_where_in)",
            params => [$broker_loginids->{$broker}->@*],
            broker => $broker,
            };
    }

    return $queries;
}

=head2 social_responsibility_queries

Gets the needed queries to hit the social_responsibility table on the users db for the audit trail.

Takes the following arguments:

=over 4

=item * C<$loginid> - The loginid of the current client.

=back

Returns an arrayref of  database queries.

=cut

sub social_responsibility_queries {
    my $loginid            = shift;
    my $client             = BOM::User::Client->new({loginid => $loginid}) || die "Cannot find client: $loginid";
    my $binary_user_id     = $client->binary_user_id;
    my $queries            = [];
    my @interesting_fields = qw/sr_risk_status/;
    my $query              = "tbl = ? AND binary_user_id = ?";

    # Since audittable stores data as JSON we may only want to retrieve those records that
    # contains changes in our interesting fields.

    $query = join ' AND ', $query, map { "(operation='INSERT' OR original_cols->'$_' IS NOT NULL)" } @interesting_fields;

    # Tell the db which fields to grab
    my $pg_userid = "COALESCE(metadata->>'staff', 'system') AS pg_userid";
    my $select    = join ',', 'stamp', 'operation', 'tbl', $pg_userid, map { "new_row->>'$_' AS $_" } @interesting_fields;

    push $queries->@*, {
        select => $select,
        table  => 'audittable',
        query  => $query,
        params => ['social_responsibility', $binary_user_id],
        broker => 'users',                                      # gonna hint the code to use UserDB
    };

    return $queries;
}

=head2 user_db_queries

Gets the needed queries to hit the users db for the audit trail.

Takes the following arguments:

=over 4

=item * C<$loginid> - The loginid of the current client.

=back

Returns an arrayref of  database queries.

=cut

sub user_db_queries {
    my $loginid            = shift;
    my $client             = BOM::User::Client->new({loginid => $loginid}) || die "Cannot find client: $loginid";
    my $binary_user_id     = $client->binary_user_id;
    my $queries            = [];
    my @interesting_fields = qw/is_totp_enabled/;
    my $query              = "tbl = ? AND binary_user_id = ?";

    # Since audittable stores data as JSON we may only want to retrieve those records that
    # contains changes in our interesting fields.

    $query = join ' AND ', $query, map { "original_cols->'$_' IS NOT NULL" } @interesting_fields;

    # Tell the db which fields to grab
    my $pg_userid = "COALESCE(metadata->>'staff', 'system') AS pg_userid";
    my $select    = join ',', 'stamp', 'tbl', $pg_userid, map { "new_row->>'$_' AS $_" } @interesting_fields;

    push $queries->@*, {
        select => $select,
        table  => 'audittable',
        query  => $query,
        params => ['binary_user', $binary_user_id],
        broker => 'users',                            # gonna hint the code to use UserDB
    };

    return $queries;
}

=head2 edd_status_queries

Gets the needed queries to hit the edd_status table in users db for the audit trail.

Takes the following arguments:

=over 4

=item * C<$loginid> - The loginid of the current client.

=back

Returns an arrayref of database queries.

=cut

sub edd_status_queries {
    my $loginid            = shift;
    my $client             = BOM::User::Client->new({loginid => $loginid}) || die "Cannot find client: $loginid";
    my $binary_user_id     = $client->binary_user_id;
    my $queries            = [];
    my @interesting_fields = qw/status start_date last_review_date average_earnings comment reason/;
    my $query              = "tbl = ? AND binary_user_id = ?";

    return [] if $client->is_virtual;

    # Tell the db which fields to grab
    my $pg_userid = "COALESCE(metadata->>'staff', 'system') AS pg_userid";
    my $select    = join ',', 'stamp', 'tbl', 'operation', $pg_userid, map { "new_row->>'$_' AS edd_$_" } @interesting_fields;

    push $queries->@*, {
        select => $select,
        table  => 'audittable',
        query  => $query,
        params => ['edd_status', $binary_user_id],
        broker => 'users',                           # gonna hint the code to use UserDB
    };

    return $queries;
}

=head2 affiliate_queries

Gets the needed queries to hit the affiliate table in users db for the audit trail.

Takes the following arguments:

=over 4

=item * C<$loginid> - The loginid of the current client.

=back

Returns an arrayref of database queries.

=cut

sub affiliate_queries {
    my $loginid            = shift;
    my $client             = BOM::User::Client->new({loginid => $loginid}) || die "Cannot find client: $loginid";
    my $binary_user_id     = $client->binary_user_id;
    my $queries            = [];
    my @interesting_fields = qw/coc_approval/;
    my $query              = "tbl = ? AND binary_user_id = ?";

    return [] if $client->is_virtual;

    # Tell the db which fields to grab
    my $pg_userid = "COALESCE(metadata->>'staff', 'system') AS pg_userid";
    my $select    = join ',', 'stamp', 'tbl', 'operation', $pg_userid, map { "new_row->>'$_' AS affiliate_$_" } @interesting_fields;

    push $queries->@*,
        {
        select => $select,
        table  => 'audittable',
        query  => $query,
        params => ['affiliate', $binary_user_id],
        broker => 'users',
        };

    return $queries;
}
