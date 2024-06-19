package BOM::Database::AutoGenerated::Rose::AccountTransfer::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::AccountTransfer;

sub object_class { 'BOM::Database::AutoGenerated::Rose::AccountTransfer' }

__PACKAGE__->make_manager_methods('account_transfer');

1;

