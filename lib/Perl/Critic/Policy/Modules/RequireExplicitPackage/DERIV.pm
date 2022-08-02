package Perl::Critic::Policy::Modules::RequireExplicitPackage::DERIV;
use strict;
use warnings;
use parent qw(Perl::Critic::Policy::Modules::RequireExplicitPackage);
use Class::Method::Modifiers;

around violates => sub {
    my $orig = shift;
    my ( $self, $elem, $doc ) = @_;
    $doc = _replace_class($doc);
    return $orig->($self, $elem, $doc);
};

sub _replace_class{
    my $doc = shift;
    my $cloned_doc = $doc->clone();
    my $object_pad = $cloned_doc->find_first(
        sub{
            $_[1]->parent == $_[0]
                and $_[1]->isa('PPI::Statement::Include')
                and ($_[1]->type // '') eq 'use'
                and ($_[1]->module // '') eq 'Object::Pad'
            });
    return $cloned_doc unless $object_pad;
    my $class = $cloned_doc->find_first(
        sub {
            $_[1]->parent == $_[0]
                and $_[1]->isa('PPI::Statement')
                and $_[1]->child(0)->isa('PPI::Token::Word')
                and $_[1]->child(0)->literal eq 'class'
        }
        );
    return $cloned_doc unless $class;
    my $class_name = $class->find_first(
        sub{
            $_[1]->parent == $_[0]
            and $_[1]->isa('PPI::Token::Word')
            and $_[1]->literal ne 'class'
                                        });
    return $cloned_doc unless $class_name;
    $cloned_doc->remove_child($object_pad);
    my $package_code = "package $class_name;";
    my $package_doc = PPI::Document->new(\$package_code);
    my $package_statement = $package_doc->find_first(sub{$_[1]->isa('PPI::Statement::Package')});
    $package_doc->remove_child($package_statement);
    $class->insert_before($package_statement);
    return $cloned_doc;
}
1;