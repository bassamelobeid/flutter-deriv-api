package BOM::Database::AutoGenerated::Rose::QuestionsAnswered::Manager;

use strict;

use base qw(Rose::DB::Object::Manager);

use BOM::Database::AutoGenerated::Rose::QuestionsAnswered;

sub object_class { 'BOM::Database::AutoGenerated::Rose::QuestionsAnswered' }

__PACKAGE__->make_manager_methods('questions_answered');

1;

