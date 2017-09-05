package BOM::Backoffice::CustomCommissionTool;

use strict;
use warnings;

use BOM::Backoffice::Request;
use 

sub generate_commission_form {
    my $url = shift;

    return BOM::Backoffice::Request::template->process(
        'backoffice/custom_commission_form.html.tt',
        {
            ee_upload_url => $url,
        },
    ) || die BOM::Backoffice::Request::template->error;
}

1;
