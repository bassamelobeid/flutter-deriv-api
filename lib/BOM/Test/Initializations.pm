package BOM::Test::Initializations;

use strict;
use warnings;
use BOM::Test::Time;    # load this early to ensure Test::MockTime is loaded before other modules

use BOM::Test::Data::Utility::FeedTestDatabase qw(:init);
use BOM::Test::Data::Utility::UnitTestMarketData qw(:init);
use BOM::Test::Data::Utility::UnitTestDatabase qw(:init);

1;
