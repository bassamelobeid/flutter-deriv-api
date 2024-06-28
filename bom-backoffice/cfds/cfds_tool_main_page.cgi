#!/etc/rmg/bin/perl
package main;

use strict;
use warnings;

use Date::Utility;
use HTML::Entities;

use f_brokerincludeall;
use BOM::Platform::Event::Emitter;
use BOM::Backoffice::PlackHelpers qw( PrintContentType );
use Syntax::Keyword::Try;

BOM::Backoffice::Sysinit::init();
PrintContentType();

BrokerPresentation("CFDS TOOLS");

Bar("CFDS Platform Config");

print qq~<div>
            <h3>CFDS Platform Config</h3>
            <form action="~ . request()->url_for('backoffice/cfds/cfds_platform_config/cfds_platform_config.cgi') . qq~" method="get">
                <input type="submit" class="btn btn--primary" value="CFDS Platform Config">
            </form>
        </div>~;

code_exit_BO();
