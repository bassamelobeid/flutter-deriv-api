package BOM::Backoffice::Utility;

use strict;
use warnings;

use BOM::Backoffice::PlackHelpers qw( http_redirect PrintContentType );
use BOM::Backoffice::Request qw(request);
use BOM::StaffPages;
use Try::Tiny;

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
    my $brand        = request()->brand;
    my $website_name = lc($brand->website_name);
    return main::code_exit_BO(
        "WARNING! You are not on the Master Live Server. Please go to the following link: https://collector01.$website_name/d/backoffice/f_broker_login.cgi"
    );
}

sub redirect_login {
    try {
        PrintContentType();
        BOM::StaffPages->instance->login();
    }
    catch {
        my $login = request()->url_for("backoffice/f_broker_login.cgi", {_r => rand()});
        print <<EOF;
<script>
    window.location = "$login";
</script>
EOF

    };
    main::code_exit_BO();
    return;
}

1;

__END__
