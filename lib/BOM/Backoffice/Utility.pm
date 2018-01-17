package BOM::Backoffice::Utility;

use strict;
use warnings;

sub get_languages {
    return {
        EN    => 'English',
        DE    => 'Deutsch',
        FR    => 'French',
        ID    => 'Indonesian',
        JA    => 'Japanese',
        PL    => 'Polish',
        PT    => 'Portuguese',
        RU    => 'Russian',
        TH    => 'Thai',
        VI    => 'Vietnamese',
        ZH_CN => 'Simplified Chinese',
        ZH_TW => 'Tradition Chinese'
    };
}

1;

__END__
