# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use List::Util qw(pairgrep);
use JSON::MaybeXS;

use constant {
    MT_RET_OK                   => 0,
    MT_RET_USR_INVALID_PASSWORD => 3006,
};

# Mocked account details
# This hash shared between two files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '123454321',
    password => 'Efgh4567',
    email    => 'test.account@binary.com',
    name     => 'Test',
    group    => 'real\costarica',
    country  => 'Malta',
    balance  => '1234.56',
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
    my ($input) = @_;

    $input->{email} eq $DETAILS{email}
        or die "TODO: mock UserAdd on unknown email\n";

    $input->{country} eq $DETAILS{country}
        or die "UserAdd with unexpected country=$input->{country}\n";
    $input->{mainPassword} eq $DETAILS{password}
        or die "UserAdd with unexpected mainPassword=$input->{mainPassword}\n";
    $input->{group} eq $DETAILS{group}
        or die "UserAdd with unexpected group=$input->{group}\n";

    return {
        ret_code => MT_RET_OK,
        login    => $DETAILS{login},
    };
}

sub cmd_UserDepositChange {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserDepositChange on unknown login\n";

    # This command is invoked for both deposits and withdrawals, the sign of
    # the amount indicating which
    # Additionally as this is a demo account it is precharged with 10000 on setup
           $input->{new_deposit} == 10000
        or $input->{new_deposit} == 150
        or $input->{new_deposit} == -150
        or die "TODO: mock UserDepositChange on unknown new_deposit amount\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserGet {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserGet on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        user     => {pairgrep { $a ne "password" } %DETAILS},
    };
}

sub cmd_UserUpdate {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{name} eq "Test2"
        or die "UserUpdate with unexpected name$input->{name}\n";
    $input->{country} eq $DETAILS{country}
        or die "UserUpdate with unexpected country=$input->{country}\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            (pairgrep { $a ne "password" } %DETAILS),
            name => "Test2",
        },
    };
}

sub cmd_UserPasswordChange {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{new_password} eq "Ijkl6789"
        or die "UserPasswordChange with unexpected new_password=$input->{new_password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserPasswordCheck {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{password} eq $DETAILS{password} or return {
        ret_code => MT_RET_USR_INVALID_PASSWORD,
        error    => 'Invalid account password',
    };

    return {
        ret_code => MT_RET_OK,
    };
}
