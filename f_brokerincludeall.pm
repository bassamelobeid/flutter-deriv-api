use lib qw(. .. ../subs ../oop);

use subs::subs_presentation_backoffice;

use subs::subs_backoffice_security;
use subs::subs_backoffice_statistics;
use subs::subs_backoffice_clientdetails;

use subs::subs_backoffice_reports;

use subs::subs_backoffice_forms;
use subs::subs_backoffice_save;

use BOM::Utility::Date;
use BOM::System::Exceptions;
use BOM::Platform::Auth0;
use BOM::Platform::Context qw(request localize);
use BOM::Platform::Client;
use BOM::Market::Underlying;

1;
