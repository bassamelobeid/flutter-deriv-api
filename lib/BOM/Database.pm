package BOM::Database;

use strict;
use warnings;

use parent qw(Exporter);

=head1 NAME

BOM::Database

=head1 DESCRIPTION

Generic database handling utilities.

Currently provides a minimal database handle tracking facility, allowing code
to request a transaction against all active database handles.

=cut

use Scalar::Util qw(weaken refaddr);
use List::UtilsBy qw(extract_by);

our @EXPORT_OK = qw(register_dbh release_dbh txn);

# List of all retained handles. Since we don't expect to update the list
# often, and the usual action is to iterate through them all in sequence,
# we're using an array rather than a hash.
# Each $dbh will be stored as a weakref: all calls to register_dbh should
# be matched with a release_dbh or global destruction, but we can recover
# (and complain) if that doesn't happen.
our @DBH;

# Where we registered the dbh originally
our %DBH_SOURCE;

=head2 register_dbh

Records the given database handle as being active and available for running transactions against.

Returns the database handle.

Example:

    sub _dbh {
        my $dbh = DBI->connect('dbi:Pg', '', '', { RaiseError => 1});
        return BOM::Database::register_dbh($dbh);
    }

=cut

sub register_dbh {
    my ($dbh) = @_;
    die "too many parameters to register_dbh: @_" if @_;
    my $addr = refaddr $dbh;
    if(exists $DBH_SOURCE{$addr}) {
        warn "already registered this database handle at " . $DBH_SOURCE{$addr};
        return;
    }
    push @DBH, $dbh;
    # filename:line (package::sub)
    $DBH_SOURCE{$addr} = sprintf "%s:%d (%s::%s)", (caller 1)[1,2,0,3];
    weaken($DBH[-1]);
    $dbh
}

=head2 register_dbh

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
    my ($dbh) = @_;
    die "too many parameters to release_dbh: @_" if @_;
    my $addr = refaddr $dbh;
    delete $DBH_SOURCE{$addr};
    # avoiding grep here because these are weakrefs and we want them to stay that way
    extract_by { $_ == $addr } @DBH;
    $dbh
}

=head2 txn

Runs the given coderef in a transaction.

Will call L<DBI/begin_work> for every known database handle, run the code, then call
L<DBI/commit> on success, or L<DBI/rollback> on failure.

Will raise an exception on failure, or return an empty list on success.

Example:

    txn { dbh()->do('NOTIFY something') };

=cut

sub txn(&;@) {
    my $code = shift;
    if(my $count =()= extract_by { !defined($_) } @DBH) {
        warn "Had $count database handles that were not released via release_dbh, probable candidates follow:\n";
        my %addr = map {; refaddr($_) => 1 } @DBH;
        warn "unreleased dbh in $_\n" for sort delete @DBH_SOURCE{grep !exists $addr{$_}, keys %DBH_SOURCE};
    }

    eval {
        $_->begin_work for @DBH;
        $code->(@_);
        $_->commit for grep defined, @DBH; # might have closed database handle(s) in $code
        1
    } or do {
        my $err = $@;
        warn "Error in transaction: $err";
        eval {
            $_->rollback;
            1
        } or warn "after $err also had failure in rollback: $@" for grep defined, @DBH;
        die $err;
    };
    return;
}

1;

