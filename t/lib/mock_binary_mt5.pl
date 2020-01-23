# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/user.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use List::Util qw(pairgrep);
use JSON::MaybeXS;

use constant {
    MT_RET_OK          => 0,
    MT_RET_ERR_TIMEOUT => 9,
};

# Mocked account details
# This hash shared between two files, and should be kept in-sync to avoid test failures
#   t/BOM/user.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS_REAL = (
    login => '1000',
    group => 'real\something',
);

my %DETAILS_DEMO = (
    login => '2000',
    group => 'demo\something',
);

my $json = JSON::MaybeXS->new;

my $cmd   = shift @ARGV;
my $input = $json->decode(
    do { local $/; <STDIN> }
);

if (my $code = main->can("cmd_$cmd")) {
    my $output = $code->($input);
    print $json->encode($output) . "\n";
    exit 0;
} else {
    print STDERR "Unrecognised command $cmd\n";
    exit 1;
}

sub cmd_UserAdd {
    # We want to assume that this is always timing out for the sake of testing.
    my ($input) = @_;
    return {
        ret_code => MT_RET_ERR_TIMEOUT,
        error    => 'ConnectionTimeout',
    };

}

sub cmd_UserDepositChange {
    # Not used by any bom-user tests
}

sub cmd_UserGet {
    my ($input) = @_;

    return {
        ret_code => MT_RET_OK,
        user     => {pairgrep { $a ne "password" } %DETAILS_REAL},
    } if $input->{login} eq $DETAILS_REAL{login};

    return {
        ret_code => MT_RET_OK,
        user     => {pairgrep { $a ne "password" } %DETAILS_DEMO},
    } if $input->{login} eq $DETAILS_DEMO{login};

    die "TODO: mock UserGet on unknown login\n";
}

sub cmd_UserUpdate {
    # Not used by any bom-user tests
}

sub cmd_UserPasswordChange {
    # Not used by any bom-user tests
}

sub cmd_UserPasswordCheck {
    # Not used by any bom-user tests
}
