package BOM::RPC::v3::CopyTrading;

use strict;
use warnings;

use BOM::Platform::Client;
use BOM::Database::ClientDB;
use BOM::Platform::Context qw (localize);

sub start_copy {
    my $params = shift;
    my $args   = $params->{args};

    my $trader_token  = $args->{copy_start};
    my $token_details = BOM::RPC::v3::Utility::get_token_details($trader_token);

    my $trader = BOM::Platform::Client->new({loginid => $token_details->{loginid}});
    my $client = $params->{client};

    if ($client->broker_code ne $trader->broker_code) {
        return BOM::RPC::v3::Utility::create_error({
                code              => 'ERROR!',
                message_to_client => localize('ERROR!')});
    }

    return;
}

1;

__END__
