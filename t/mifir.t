use 5.014;
use warnings;
use strict;
use Test::More;
use BOM::Backoffice::MIFIR;
use utf8;

is BOM::Backoffice::MIFIR::concat({
        cc         => 'fr',
        date       => '17-03-1986',
        first_name => 'Elisabeth',
        last_name  => 'Doe',
    }
    ),
    'FR19860317ELISADOE##', 'Elisabeth Doe, born 17th March 1986, French national:';

is BOM::Backoffice::MIFIR::concat({
        cc         => 'se',
        date       => '02-12-1944',
        first_name => 'Robert',
        last_name  => 'O’Neal',
    }
    ),
    'SE19441202ROBERONEAL', 'Robert O\'Neal, born 2nd December 1944, national of Sweden and Canada';

is BOM::Backoffice::MIFIR::concat({
        cc         => 'AT',
        date       => '27-05-1955',
        first_name => 'Dr Joseph',
        last_name  => 'van der Strauss',
    }
    ),
    'AT19550527JOSEPSTRAU', 'Dr Joseph van der Strauss, born 27th May 1955, national of Austria and Germany';

is BOM::Backoffice::MIFIR::_process_name('Аркадий'),       'arkad', 'russian check';
is BOM::Backoffice::MIFIR::_process_name('Стругацкий'), 'strug', 'russian check';
is BOM::Backoffice::MIFIR::_process_name('АЙЗЕК'),           'aizek', 'russian check';
is BOM::Backoffice::MIFIR::_process_name('Азимов'),         'azimo', 'russian check';
is BOM::Backoffice::MIFIR::_process_name('Бьёрн'),           'bern#', 'russian check';
is BOM::Backoffice::MIFIR::_process_name('Страуструп'), 'strau', 'russian check';

done_testing();
