package BOM::Database::Rose::DB::Object::AutoBase1;

use strict;
use warnings;

use Try::Tiny;

use base 'Rose::DB::Object';
use Rose::DB::Object::Util qw(:get_state);

use BOM::Database::Rose::DB;
use BOM::Database::ClientDB;
use Rose::DB::Object::Metadata::Relationship::OneToMany;

# The default list of generated methods for one-many relationships does not include
# 'count_' and 'iterator_' methods so add them now (before meta->setup calls in derived classes).
Rose::DB::Object::Metadata::Relationship::OneToMany->default_auto_method_types(qw(find get_set_on_save add_on_save count iterator));

# This is a base class for the code-generated RoseDB-classes.  We provide an optional 'broker'
# property so that, if supplied, a suitable database read/write connection pair can
# be generated into local db_{read|write} attributes.  If not supplied, a default
# connection is generated.  Note also we defer creation of the write-connection until needed by a save.

use overload '""' => sub { shift->safe_stringify }; ## no critic (OverloadOptions)

sub safe_stringify {
    my $self = shift;
    return is_in_db($self) ? $self->stringify : $self;
}

sub stringify {
    my $self = shift;
    return ref $self;
}

# Try and supply 'broker' (if missing), from any available loginid or client_loginid columns.
# If successful then writes will be able to use the correct db handle.
sub broker {
    my $self = shift;
    return $self->{_broker} = $_[0] if @_;    # set
    return $self->{_broker} ||= do {          # get
        my $broker;
        {
            my $loginid =
                   ($self->can('loginid') && $self->loginid)
                || ($self->can('client_loginid') && $self->client_loginid)
                || last;

            ($loginid =~ /^([A-Z]+)/) ? $broker = $1 : last;
        }
        $broker;
        }
}

sub get_db { return shift->{_db_operation} || '' }

sub set_db {
    my ($self, $operation) = @_;
    my $db = BOM::Database::ClientDB->new({
            broker_code => ($self->broker || die "must know broker to set db"),
            operation => $operation,
        })->db;
    $self->{_db_operation} = $operation;
    return $self->db($db);
}

sub init_db {
    my $self = shift;
    return (ref $self && $self->broker)
        ? $self->set_db('write')
        : BOM::Database::Rose::DB->new;
}

sub _set_staff {
    my $self = shift;
    my $db   = $self->db;
    # db->type here is the "operation". We will not audit operation values such as 'collector'.
    # db names are like costarica-backoffice_replica costarica-replica costarica-write
    # There can be multiple updates per one session, and every audit trigger will clear the table.
    # so we need to populate this table again before every change
    if ($db->database =~ /^\w+-\w+$/ && $db->type eq 'write') {
        my $staff = $ENV{AUDIT_STAFF_NAME} || 'system';
        my $ip    = $ENV{AUDIT_STAFF_IP}   || '127.0.0.1';

        $db->dbic->run(sub { $_->do('select audit.set_staff(?,?)', undef, $staff, $ip) });
    }
    return;
}

sub delete {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
    my ($self, @args) = (shift, @_);
    $self->_set_staff;
    return $self->SUPER::delete(@args);
}

sub save {
    my ($self, @args) = (shift, @_);
    $self->_set_staff;
    return $self->SUPER::save(@args);
}

1;
