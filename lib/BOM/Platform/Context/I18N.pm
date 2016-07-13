package BOM::Platform::Context::I18N;

use feature 'state';
use strict;
use warnings;

use BOM::Platform::Context::I18N::Base {
    'EN'      => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/en.po'],
    '*'       => ['Gettext' => '/home/git/binary-com/translations-websockets-api/src/locales/*.po'],
    '_auto'   => 1,
    '_decode' => 1,
};

sub handle_for {
    my $language = shift;

    state %handles;
    $language = lc $language;
    return $handles{$language} //= BOM::Platform::Context::I18N::Base->get_handle($language);
}

1;
