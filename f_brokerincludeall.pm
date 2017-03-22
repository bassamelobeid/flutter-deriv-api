## no critic (RequireExplicitPackage)
use strict;
use warnings;
use lib qw(. .. ../subs ../oop);

use subs::subs_presentation_backoffice;

use subs::subs_backoffice_clientdetails;

use subs::subs_backoffice_reports;

use subs::subs_backoffice_forms;
use subs::subs_backoffice_save;

use subs::subs_backoffice_suspected_clients;

use Date::Utility;
use BOM::Backoffice::Auth0;
use Client::Account;
use BOM::MarketData qw(create_underlying);
use BOM::MarketData::Types;
1;
