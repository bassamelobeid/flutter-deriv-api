package BOM::Database::AutoGenerated::Rose::Cryptocurrency::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::Cryptocurrency;

sub object_class { 'BOM::Database::AutoGenerated::Rose::Cryptocurrency' }

__PACKAGE__->make_manager_methods('cryptocurrency');

1;

