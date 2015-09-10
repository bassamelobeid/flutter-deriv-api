#!/usr/bin/perl -w -I ./cgi -I ./cgi/oop

package RMG::UnderlyingsTranslator;

use Moose;
with 'App::Base::Script';
with 'BOM::Utility::Logging';

use IO::File;
use Module::Load::Conditional qw( can_load );
use YAML::CacheLoader qw(LoadFile);

use BOM::Market::Registry;
use BOM::Market::SubMarket::Registry;
use BOM::Product::Offerings qw(get_offerings_with_filter);
use BOM::Market::Underlying;
use BOM::Market::UnderlyingDB;

has file_container => (
    is         => 'ro',
    isa        => 'ArrayRef[Str]',
    lazy_build => 1,
);

sub _build_file_container {
    my $self        = shift;
    my $current_pot = IO::File->new($self->pot_filename, 'r');
    my @content     = <$current_pot>;
    return [map { chomp; $_ } @content];
}

has pot_filename => (
    is      => 'rw',
    isa     => 'Str',
    default => '',
);

has pot_append_fh => (
    is         => 'ro',
    isa        => 'IO::File',
    lazy_build => 1,
);

sub _build_pot_append_fh {
    my $self = shift;
    return IO::File->new($self->pot_filename, 'a');
}

sub documentation {
    return "Populates our pot file with translations that are not directly picked up by xgettext.pl. Run it with the location to pot file.";
}

sub cli_template {
    return "$0 [options] messages.po";
}

sub script_run {
    my ($self, $pot_filename) = @_;

    die "Unable to open $pot_filename for writing" if (not -w $pot_filename);

    $self->pot_filename($pot_filename);
    my $fh = $self->pot_append_fh;

    print $fh "\n# Start of extra_translations\n";
    $self->add_underlyings;
    $self->add_contract_categories;
    $self->add_contract_types;

    return 0;
}

sub add_underlyings {
    my $self = shift;

    my @underlyings = map {BOM::Market::Underlying->new($_)} BOM::Market::UnderlyingDB->get_symbols_for(market => [BOM::Market::Registry->all_market_names], exclude_disabled => 1);

    my $fh = $self->pot_append_fh;

    foreach my $underlying (@underlyings) {
        next unless $underlying->{display_name};
        my $msgid = $self->msg_id($underlying->{display_name});
        if ($self->is_id_unique($msgid)) {
            print $fh "\n";
            print $fh "#: Underlying Symbol " . $underlying->{symbol} . "\n";
            print $fh $msgid . "\n";
            print $fh "msgstr \"\"\n";
        }
    }

    $self->add_markets;
    $self->add_submarkets;

    return 0;
}

sub add_contract_types {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    foreach my $contract_type (get_offerings_with_filter('contract_type')) {
        my $contract_class = 'BOM::Product::Contract::' . ucfirst lc $contract_type;
        if (not can_load(modules => {$contract_class => undef})) {
            $contract_class = 'BOM::Product::Contract::Invalid';
            can_load(module => {$contract_class => undef});    # No idea what to do if this fails.
        }

        if ($contract_class->display_name) {
            my $msgid = $self->msg_id($contract_class->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Translation for contract type \"" . $contract_class->code . "\"\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
        if ($contract_class->localizable_description) {
            foreach my $description_key (sort keys %{$contract_class->localizable_description}) {
                my $msgid = $self->msg_id($contract_class->localizable_description->{$description_key});
                if ($self->is_id_unique($msgid)) {
                    print $fh "\n";
                    print $fh "#. %1 - Payout Currency (example USD)\n";
                    print $fh "#. %2 - Payout value (example 100)\n";
                    print $fh "#. %3 - Underlying name (example USD/JPY)\n";
                    print $fh "#. %4 - Starting datetime (may be 'contract start')\n";
                    print $fh "#. %5 - Expiration datetime\n";
                    print $fh "#. %6 - High (or single) barrier\n";
                    print $fh "#. %7 - Low barrier (when present)\n";
                    print $fh "#: Translation for contract type description (".$contract_class->code.' - '.$description_key.")\n";
                    print $fh $msgid . "\n";
                    print $fh "msgstr \"\"\n";
                }
            }
        }
    }

    return;
}

sub add_contract_categories {
    my $self = shift;

    my $fh = $self->pot_append_fh;
    my @all_categories = map {BOM::Product::Contract::Category->new($_)} keys %{LoadFile('/home/git/regentmarkets/bom/config/files/contract_categories.yml')};
    foreach my $contract_category (@all_categories) {
        if ($contract_category->display_name) {
            my $msgid = $self->msg_id($contract_category->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Translation for contract category \"" . $contract_category->code . "\"\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
        if ($contract_category->explanation) {
            my $msgid = $self->msg_id($contract_category->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Explanation for contract category " . $contract_category->display_name . "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub add_markets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    foreach my $market (BOM::Market::Registry->all) {
        if ($market->display_name) {
            my $msgid = $self->msg_id($market->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Translation for market name\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }

        if ($market->explanation) {
            my $msgid = $self->msg_id($market->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Explanation for market " . $market->display_name . "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }
    return;
}

sub add_submarkets {
    my $self = shift;

    my $fh = $self->pot_append_fh;

    foreach my $submarket (BOM::Market::SubMarket::Registry->all) {
        if ($submarket->display_name) {
            my $msgid = $self->msg_id($submarket->display_name);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Translation for sub market name\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }

        if ($submarket->explanation) {
            my $msgid = $self->msg_id($submarket->explanation);
            if ($self->is_id_unique($msgid)) {
                print $fh "\n";
                print $fh "#: Explanation for market " . $submarket->display_name . "\n";
                print $fh $msgid . "\n";
                print $fh "msgstr \"\"\n";
            }
        }
    }

    return;
}

sub is_id_unique {
    my ($self, $key) = @_;

    my $flag = 0;
    if (not exists $self->_extant_msg_ids->{$key}) {
        $flag = 1;
        $self->_extant_msg_ids->{$key} = undef;
    }

    return $flag;
}

sub msg_id {
    my $self = shift;
    my $string = shift;
    $string =~ s/\[_(\d)\]/%$1/g;
    return "msgid \"$string\"";
}

has _extant_msg_ids => (
    is         => 'ro',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build__extant_msg_ids {
    my $self = shift;

    return {map { $_ => undef } grep { /^msgid / } (@{$self->file_container})};
}

no Moose;
__PACKAGE__->meta->make_immutable;

package main;
use strict;

exit RMG::UnderlyingsTranslator->new->run;
