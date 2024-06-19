package BOM::Database::AutoGenerated::Rose::AppMarkupPayable::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::AppMarkupPayable;

sub object_class { 'BOM::Database::AutoGenerated::Rose::AppMarkupPayable' }

__PACKAGE__->make_manager_methods('app_markup_payable');

1;

