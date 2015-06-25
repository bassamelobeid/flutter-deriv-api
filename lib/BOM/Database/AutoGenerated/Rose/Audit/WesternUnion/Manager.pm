package BOM::Database::AutoGenerated::Rose::Audit::WesternUnion::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::Audit::WesternUnion;

sub object_class { 'BOM::Database::AutoGenerated::Rose::Audit::WesternUnion' }

__PACKAGE__->make_manager_methods('western_union');

1;

