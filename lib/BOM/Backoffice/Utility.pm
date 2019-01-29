package BOM::Backoffice::Utility;

use strict;
use warnings;

use Exporter qw(import export_to_level);

our @EXPORT_OK = qw(get_languages master_live_server_error);

sub get_languages {
    return {
        EN    => 'English',
        DE    => 'Deutsch',
        FR    => 'French',
        ID    => 'Indonesian',
        PL    => 'Polish',
        PT    => 'Portuguese',
        RU    => 'Russian',
        TH    => 'Thai',
        VI    => 'Vietnamese',
        ZH_CN => 'Simplified Chinese',
        ZH_TW => 'Traditional Chinese'
    };
}

sub master_live_server_error {
    return main::code_exit_BO(
        "WARNING! You are not on the Master Live Server. Please go to the following link: https://collector01.binary.com/d/backoffice/f_broker_login.cgi"
    );
}

1;

__END__
