use strict;
use warnings;

use Test::More;
use File::Basename;
use Dir::Self;
use Digest::SHA1;

use constant TICKS_SCHEMA         => 'config/v3/ticks/receive.json';
use constant TICKS_HISTORY_SCHEMA => 'config/v3/ticks_history/receive.json';

my $directory = dirname(__DIR__);

subtest 'validate ticks file hash' => sub {
    open(my $fh, "<", TICKS_SCHEMA) or die "File not found @{[TICKS_SCHEMA]}";
    is(Digest::SHA1->new->addfile($fh)->hexdigest, '3208188cefdd09da8490d648594da7a8a523205b', 'Ticks file is unchanged')
        or diag
        'We have removed type coercion to improve the API performance for the ticks call. Please update the code if type of any property under `tick` is updated. Please refer https://github.com/regentmarkets/binary-websocket-api/pull/6249 for more details.';
};

subtest 'validate ticks_history file hash' => sub {
    open(my $fh, "<", TICKS_HISTORY_SCHEMA) or die "File not found @{[TICKS_HISTORY_SCHEMA]}";
    is(Digest::SHA1->new->addfile($fh)->hexdigest, '7cfd46946d247d82051f61ab2a3396965a318f2c', 'Ticks file is unchanged')
        or diag
        'We have removed type coercion to improve the API performance for the ticks call. Please update the code if type of any property under `ohlc` is updated. Please refer https://github.com/regentmarkets/binary-websocket-api/pull/6249 for more details.';
};

done_testing;
