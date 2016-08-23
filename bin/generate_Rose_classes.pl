#!/etc/rmg/bin/perl

use strict;
use warnings;

use Rose::DB::Object::Loader;
use Lingua::EN::Inflect;

my $dbname = shift;
my $schema = shift;
my $tmpdir = shift || die "usage: $0 DBNAME SCHEMANAME TMPDIR [SUBDIR]\n";
my $subdir = shift;

my $sublevel = $subdir ? ("::" . ucfirst(lc($schema))) : '';

{
    no warnings 'redefine';
    #############################################################
    # OVERRIDE BROKEN ROSE CODE_GENERATION: (not punching schema!)
    #############################################################
    sub Rose::DB::Object::Metadata::Auto::perl_table_definition {
        my ($self, %args) = @_;
        my $for_setup = $args{'for_setup'};
        my $indent    = defined $args{'indent'} ? $args{'indent'} : $self->default_perl_indent;
        my $table     = $self->table;
        $table =~ s/'/\\'/;
        if ($args{'for_setup'}) {
            $indent = ' ' x $indent;
            return qq(${indent}table   => '$table',\n) . qq(${indent}schema   => '$schema',);
        }
        return qq(__PACKAGE__->meta->table('$table'););
    }
    #############################################################
    # OVERRIDE BROKEN ROSE PLURAL_TO_SINGULAR CONVERSION
    # This chunk of code is copied (and then uncluttered) from
    # the original but patched to not convert '*status' to '*statu'
    #############################################################
    sub Rose::DB::Object::ConventionManager::plural_to_singular {
        my ($self, $word) = @_;
        for ($word) {
            s/ies$/y/i      && last;
            s/ses$/s/i      && last;
            m/[aeiouy]ss$/i && last;
            m/us$/i         && last;    # this is the new rule
            s/s$//i         && last;
        }
        return $word;
    }
}

#############################################################
# GO
#############################################################

my $convention_manager = Rose::DB::Object::ConventionManager->new(
    tables_are_singular         => 0,                           # prefer 1 but too much code already written
    singular_to_plural_function => \&Lingua::EN::Inflect::PL,
);

my $loader = Rose::DB::Object::Loader->new(
    db_dsn      => "dbi:Pg:dbname=$dbname;host=localhost",
    db_username => 'postgres',
    db_password => 'mRX1E3Mi00oS8LG',
    db_options  => {
        AutoCommit => 1,
        ChopBlanks => 1
    },
    db_schema           => $schema,
    base_class          => 'BOM::Database::Rose::DB::Object::AutoBase1',
    class_prefix        => "BOM::Database::AutoGenerated::Rose$sublevel",
    module_dir          => $tmpdir,
    convention_manager  => $convention_manager,
    require_primary_key => 0,
);

printf "For schema: $schema.. ";
#my @classes = $loader->make_modules;
my @classes = $loader->make_modules(
    'post_init_hook'=> \&generateFMB_relationships
    );
#printf "Made $_\n" for @classes;
printf "%d modules made.\n", scalar(@classes);
# if zero classes built, exit with a non-zero result..
exit(@classes == 0);

sub employHacks
{
    my $metaObj = shift;
    generateFMB_relationships($metaObj);
    forceUnqEmailOnBinaryUser($metaObj);
}

sub forceUnqEmailOnBinaryUser
{
    my $metaObj = shift;
    return unless $metaObj->{'class'} eq 'BOM::Database::AutoGenerated::Rose::BinaryUser'
    $metaObj->add_unique_keys('email');
}

# this is necessary now that formal fkeys no longer exist between these tables
sub generateFMB_relationships
{
    my $metaObj = shift;
    return unless $metaObj->{'class'} eq 'BOM::Database::AutoGenerated::Rose::FinancialMarketBet' || $metaObj->{'class'} eq 'BOM::Database::AutoGenerated::Rose::FinancialMarketBetOpen';
#    use Data::Dumper; print Dumper($metaObj); die;
    $metaObj->add_relationships(
        digit_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::DigitBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },
        
        higher_lower_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::HigherLowerBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },
        
        legacy_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::LegacyBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },

        range_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::RangeBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },

        run_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::RunBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },

        spread_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::SpreadBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },

        touch_bet => {
            class                => 'BOM::Database::AutoGenerated::Rose::TouchBet',
            column_map           => { id => 'financial_market_bet_id' },
            type                 => 'one to one',
        },
    );
}