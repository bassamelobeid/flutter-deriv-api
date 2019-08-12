# This script contains a mocked MT5 wrapper command used by the tests in t/BOM/RPC/30_mt5.t and t/BOM/RPC/05_accounts.t

use strict;
use warnings;

use open ':encoding(UTF-8)';
use List::Util qw(pairgrep first);
use JSON::MaybeXS;

use constant {
    MT_RET_OK                   => 0,
    MT_RET_USR_INVALID_PASSWORD => 3006,
};

# Mocked account details

# %ACCOUNTS and %DETAILS are shared between four files, and should be kept in-sync to avoid test failures
#   t/BOM/RPC/30_mt5.t
#   t/BOM/RPC/05_accounts.t
#   t/BOM/RPC/Cashier/20_transfer_between_accounts.t
#   t/lib/mock_binary_mt5.pl

# Account numbers to be assigned to new accounts.
# Add here if your test uses a new group.
my %ACCOUNTS = (
    'demo\vanuatu_standard'         => '00000001',
    'demo\vanuatu_advanced'         => '00000002',
    'demo\labuan_standard'          => '00000003',
    'demo\labuan_advanced'          => '00000004',
    'real\malta'                    => '00000010',
    'real\maltainvest_standard'     => '00000011',
    'real\maltainvest_standard_GBP' => '00000012',
    'real\svg'                      => '00000013',
    'real\vanuatu_standard'         => '00000014',
    'real\labuan_advanced'          => '00000015',
);

my %DETAILS = (
    password => {
        main     => 'Efgh4567',
        investor => 'Abcd1234',
    },
    email   => 'test.account@binary.com',
    name    => 'Meta traderman',
    country => 'Malta',
    balance => '1234',
    landing_company => 'svg'
);

my %GROUP_DETAILS = (
    currency => 'USD',
    group    => 'real\svg',
    leverage => 300,
    company => 'Binary (SVG) Ltd.'
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

    exists $ACCOUNTS{$input->{group}} or die "UserAdd with unexpected group=$input->{group}\n";

    $input->{mainPassword} eq $DETAILS{password}->{main}
        or die "UserAdd with unexpected mainPassword=$input->{mainPassword}\n";

    $input->{investPassword} eq $DETAILS{password}->{investor}
        or die "UserAdd with unexpected investorPassword=$input->{investPassword}\n";

    return {
        ret_code => MT_RET_OK,
        login    => $ACCOUNTS{$input->{group}},
    };
}

sub cmd_UserDepositChange {
    my ($input) = @_;

    get_account_group($input->{login})
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

    my $group = get_account_group($input->{login})
        or die "TODO: mock UserGet on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            (pairgrep { $a ne 'password' } %DETAILS),
            group => $group,
            login => $input->{login}
        }
    };
}

sub cmd_GroupGet {
    my ($input) = @_;

    return {
        ret_code => MT_RET_OK,
        group    => {
            %GROUP_DETAILS,
            group => $input->{group},
        },
    };
}

sub cmd_UserUpdate {
    my ($input) = @_;

    my $group = get_account_group($input->{login}) or die "TODO: mock UserUpdate on unknown login\n";

    $input->{name} eq "Test2"
        or die "UserUpdate with unexpected name$input->{name}\n";

    return {
        ret_code => MT_RET_OK,
        user     => {
            (pairgrep { $a ne "password" } %DETAILS),
            name => "Test2",
            group => $group
        },
    };
}

sub cmd_UserPasswordChange {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{type} eq 'main' || $input->{type} eq 'investor'
        or die "UserPasswordChange with unexpected password_type\n";

    $input->{new_password} eq "Ijkl6789" || $input->{new_password} eq "Abcd1234"
        or die "UserPasswordChange with unexpected new_password=$input->{new_password}\n";

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_UserPasswordCheck {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock UserUpdate on unknown login\n";

    $input->{password} eq $DETAILS{password}->{$input->{type}}
        or return {
        ret_code => MT_RET_USR_INVALID_PASSWORD,
        error    => 'Invalid account password',
        };

    return {
        ret_code => MT_RET_OK,
    };
}

sub cmd_PositionGetTotal {
    my ($input) = @_;

    get_account_group($input->{login})
        or die "TODO: mock PositionGetTotal on unknown login\n";

    return {
        ret_code => MT_RET_OK,
        total    => 0,
    };
}

sub get_account_group {
    my $login = shift;
    return first {$ACCOUNTS{$_} eq $login} keys %ACCOUNTS;
}
