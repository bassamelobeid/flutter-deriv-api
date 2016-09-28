package BOM::Database;

use strict;
use warnings;

use Exporter qw(import export_to_level);

=head1 NAME

BOM::Database

=head1 DESCRIPTION

Generic database handling utilities.

Currently provides a minimal database handle tracking facility, allowing code
to request a transaction against all active database handles.

=cut

use Scalar::Util qw(weaken refaddr);
use List::UtilsBy qw(extract_by);

our @EXPORT_OK = qw(register_dbh release_dbh dbh_is_registered txn);

# List of all retained handles by category. Since we don't expect to update
# the list often, and the usual action is to iterate through them all in
# sequence, we're using an array rather than a hash.
# Each $dbh will be stored as a weakref: all calls to register_dbh should
# be matched with a release_dbh or global destruction, but we can recover
# (and complain) if that doesn't happen.
my %DBH;

# Where we registered the dbh originally - top level key is category, second
# level is refaddr.
my %DBH_SOURCE;

# Last PID we saw - used for invalidating stale DBH on fork
my $PID = $$;

=head2 register_dbh

Records the given database handle as being active and available for running transactions against.

Expects a category (string value) and L<DBI::db> instance.

Returns the database handle.

Example:

    sub _dbh {
        my $dbh = DBI->connect('dbi:Pg', '', '', { RaiseError => 1});
        return BOM::Database::register_dbh(feed => $dbh);
    }

=cut

sub register_dbh {
    my ($category, $dbh) = @_;
    die "too many parameters to register_dbh: @_" if @_ > 2;
    _check_fork();
    my $addr = refaddr $dbh;
    if(exists $DBH_SOURCE{$category}{$addr}) {
        warn "already registered this database handle at " . $DBH_SOURCE{$category}{$addr};
        return;
    }
    push @{$DBH{$category}}, $dbh;
    weaken($DBH{$category}[-1]);
    # filename:line (package::sub)
    $DBH_SOURCE{$category}{$addr} = sprintf "%s:%d (%s::%s)", (caller 1)[1,2,0,3];
    $dbh
}

=head2 release_dbh

Marks the given database handle as no longer active - it will not be used for any further transaction requests
via L</txn>.

Returns the database handle.

Example:

    sub DESTROY {
        my $self = shift;
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        BOM::Database::release_dbh($self->dbh)->disconnect;
    }

=cut

sub release_dbh {
    my ($category, $dbh) = @_;
    die "too many parameters to release_dbh: @_" if @_ > 2;
    _check_fork();
    # At destruction we may have an invalid handle
    my $addr = refaddr $dbh or return $dbh;
    warn "releasing unregistered dbh $dbh" unless exists $DBH_SOURCE{$category}{$addr};
    delete $DBH_SOURCE{$category}{$addr};
    # avoiding grep here because these are weakrefs and we want them to stay that way.
    # since they're weakrefs, some of these may be undef
    extract_by { $addr == (defined($_) ? refaddr($_) : 0) } @{$DBH{$category}};
    return $dbh;
}

=head2 dbh_is_registered

Returns true if the provided database handle has been registered already.

Used when registering a handle acquired via L<DBI/connect_cached>.

    register_dbh($dbh) unless dbh_is_registered($dbh);

=cut

sub dbh_is_registered {
    my ($category, $dbh) = @_;
    die "too many parameters to register_dbh: @_" if @_ > 1;
    _check_fork();
    my $addr = refaddr $dbh;
    return exists $DBH_SOURCE{$category}{$addr} ? 1 : 0;
}

=head2 txn

Runs the given coderef in a transaction.

Expects a coderef and a database handle category.

Will call L<DBI/begin_work> for every known database handle in the given category,
run the code, then call L<DBI/commit> on success, or L<DBI/rollback> on failure.

Will raise an exception on failure, or return an empty list on success.

Example:

    txn { dbh()->do('NOTIFY something') } 'feed';

WARNING: This only applies transactions to known database handles. Anything else -
Redis, cache layers, files on disk - is out of scope. Transactions are a simple
L<DBI/begin_work> / L<DBI/commit> pair, there's no 2-phase commit or other
distributed transaction co-ordination happening here.

=cut

sub txn(&;@) {
    my ($code, $category) = @_;
    _check_fork();
    my $wantarray = wantarray;
    if(my $count =()= extract_by { !defined($_) } @{$DBH{$category}}) {
        warn "Had $count database handles that were not released via release_dbh, probable candidates follow:\n";
        my %addr = map {; refaddr($_) => 1 } @{$DBH{$category}};
        warn "unreleased dbh in $_\n" for sort delete @{$DBH_SOURCE{$category}}{grep !exists $addr{$_}, keys %DBH_SOURCE};
    }

    my @rslt;
    eval {
        $_->begin_work for @{$DBH{$category}};
        # We want to pass through list/scalar/void context to the coderef
        if($wantarray) {
            @rslt = $code->();
        } elsif(defined $wantarray) {
            $rslt[0] = $code->();
        } else {
            $code->();
        }
        _check_fork();
        $_->commit for grep defined, @{$DBH{$category}}; # might have closed database handle(s) in $code
        1
    } or do {
        my $err = $@;
        warn "Error in transaction: $err";
        eval {
            $_->rollback;
            1
        } or warn "after $err also had failure in rollback: $@" for grep defined, @{$DBH{$category}};
        die $err;
    };
    return $wantarray ? @rslt : $rslt[0];
}

=head2 _check_fork

Test whether we have forked recently, and invalidate all our caches if we have.

Returns true if there has been a fork since last check, false otherwise.

=cut

sub _check_fork {
    return 0 if $PID == $$;
    $PID = $$;
    %DBH = ();
    %DBH_SOURCE = ();
    return 1;
}

1;

