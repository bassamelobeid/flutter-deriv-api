use 5.014;
use warnings;
use strict;
use Test::More;
use BOM::Backoffice::MIFIR;

is BOM::Backoffice::MIFIR::generate({
        cc         => 'fr',
        date       => '17-03-1986',
        first_name => 'Elisabeth',
        last_name  => 'Doe',
    }
    ),
    'FR19860317ELISADOE##', 'Elisabeth Doe, born 17th March 1986, French national:';

is BOM::Backoffice::MIFIR::generate({
        cc         => 'se',
        date       => '02-12-1944',
        first_name => 'Robert',
        last_name  => 'O\'Neal',
    }
    ),
    'SE19441202ROBERONEAL', 'Robert O’Neal, born 2nd December 1944, national of Sweden and Canada';

is BOM::Backoffice::MIFIR::generate({
        cc         => 'AT',
        date       => '27-05-1955',
        first_name => 'Dr Joseph',
        last_name  => 'van der Strauss',
    }
    ),
    'AT19550527JOSEPSTRAU', 'Dr Joseph van der Strauss, born 27th May 1955, national of Austria and Germany';

done_testing();
