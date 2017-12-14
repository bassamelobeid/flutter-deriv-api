# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use JSON::MaybeXS;

use constant {
    MT_RET_OK => 0,
};

my $LOGIN = "1000";

my $json = JSON::MaybeXS->new;

my $cmd = shift @ARGV;
my $input = $json->decode(do { local $/; <STDIN> });

if(my $code = main->can("cmd_$cmd")) {
    my $output = $code->($input);
    print $json->encode($output) . "\n";
    exit 0;
}
else {
    print STDERR "Unrecognised command $cmd\n";
    exit 1;
}

sub cmd_UserAdd {
    my ($input) = @_;

    $input->{email} eq 'test.account@binary.com' or
        die "TODO: mock UserAdd on unknown email\n";

    return {
        ret_code => MT_RET_OK,
        login    => $LOGIN,
    };
}

sub cmd_UserDepositChange {
    my ($input) = @_;

    $input->{login} eq $LOGIN or
        die "TODO: mock UserDepositChange on unknown login\n";

    return {
        ret_code => MT_RET_OK,
    };
}
