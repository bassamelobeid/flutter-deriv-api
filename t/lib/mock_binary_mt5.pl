# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use List::Util qw(pairgrep);
use JSON::MaybeXS;

use constant {
    MT_RET_OK                   => 0,
    MT_RET_USR_INVALID_PASSWORD => 3006,

    WEB_VAL_USER_PASS_MAIN     => "MAIN",
    WEB_VAL_USER_PASS_INVESTOR => "INVESTOR",
};

# Mocked account details
# This hash shared between two files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/lib/mock_binary_mt5.pl
my %DETAILS = (
    login    => '123454321',
    password => {
        main     => 'Efgh4567',
        investor => 'Abcd1234',
    },
    email   => 'test.account@binary.com',
    name    => 'Test',
    group   => 'real\costarica',
    country => 'Malta',
    balance => '1234.56',
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

    $input->{mainPassword} eq $DETAILS{password}->{main}
        or die "UserAdd with unexpected mainPassword=$input->{mainPassword}\n";
    $input->{group} eq $DETAILS{group}
        or die "UserAdd with unexpected group=$input->{group}\n";

    $input->{investPassword} eq $DETAILS{password}->{investor}
        or die "UserAdd with unexpected investorPassword=$input->{investPassword}\n";

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
    $input->{new_deposit} == 10000          # initial balance
        or $input->{new_deposit} == 180     # deposit
        or $input->{new_deposit} == -150    # withdrawal
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

    $input->{type} eq WEB_VAL_USER_PASS_MAIN || $input->{type} eq WEB_VAL_USER_PASS_INVESTOR
        or die "UserPasswordChange with unexpected password_type\n";

    $input->{new_password} eq "Ijkl6789" || $input->{new_password} eq "Abcd1234"
        or die "UserPasswordChange with unexpected new_password=$input->{new_password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserPasswordCheck {
    my ($input) = @_;

    $input->{login} eq $DETAILS{login}
        or die "TODO: mock UserUpdate on unknown login\n";

    my $type = $input->{type} eq WEB_VAL_USER_PASS_INVESTOR ? 'investor' : 'main';

    $input->{password} eq $DETAILS{password}->{$type} or return {
        ret_code => MT_RET_USR_INVALID_PASSWORD,
        error    => 'Invalid account password',
    };

    return {
        ret_code => MT_RET_OK,
    };
}
