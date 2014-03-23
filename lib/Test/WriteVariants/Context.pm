package Test::WriteVariants::Context;

use strict;

my $ContextClass = __PACKAGE__;

# a Context is an ordered list of various kinds of named values (such as env vars, our vars)
# possibly including other Context objects.
#
# Values can be looked up by name. The first match will be returned.

sub new {
    my $class = shift;
    $class = ref $class if ref $class;
    return bless [ @_ ], $class;
}


sub new_composite { shift->new(@_) } # see Test::WriteVariants::Context::BaseItem


sub push_var { # add a var to an existing config
    my ($self, $var) = @_;
    push @$self, $var;
    return;
}


sub _new_var    {
    my ($self, $t, $n, $v, %e) = @_;
    my $var = $t->new($n, $v, %e);
    return $self->new( $var ); # wrap var item in a context list
}
sub new_env_var    { shift->_new_var($ContextClass.'::EnvVar', @_) }
sub new_our_var    { shift->_new_var($ContextClass.'::OurVar', @_) }
sub new_module_use { shift->_new_var($ContextClass.'::ModuleUse', @_) }
sub new_meta_info  { shift->_new_var($ContextClass.'::MetaInfo', @_) }


# XXX should ensure that a given type+name is only output once (the latest one)
sub get_code  {
    my $self = shift;
    my @code;
    for my $setting (reverse @$self) {
        push @code, (ref $setting) ? $setting->get_code : $setting;
    }
    return join "", @code;
}


sub get_var { # search backwards through list of settings, stop at first match
    my ($self, $name, $type) = @_;
    for my $setting (reverse @$self) {
        next unless $setting;
        my @value = $setting->get_var($name, $type);
        return $value[0] if @value;
    }
    return;
}

sub get_env_var    { my ($self, $name) = @_; return $self->get_var($name, $ContextClass.'::EnvVar') }
sub get_our_var    { my ($self, $name) = @_; return $self->get_var($name, $ContextClass.'::OurVar') }
sub get_module_use { my ($self, $name) = @_; return $self->get_var($name, $ContextClass.'::ModuleUse') }
sub get_meta_info  { my ($self, $name) = @_; return $self->get_var($name, $ContextClass.'::MetaInfo') }



{
    package Test::WriteVariants::Context::BaseItem;
    use strict;
    require Data::Dumper;
    require Carp;

    # base class for an item (a name-value-type triple)

    sub new {
        my ($class, $name, $value) = @_;

        my $self = bless {} => $class;
        $self->name($name);
        $self->value($value);

        return $self;
    }

    sub name {
        my $self = shift;
        $self->{name} = shift if @_;
        return $self->{name};
    }

    sub value {
        my $self = shift;
        $self->{value} = shift if @_;
        return $self->{value};
    }

    sub get_code  {
        return '';
    }

    sub get_var {
        my ($self, $name, $type) = @_;
        return if $type && !$self->isa($type);  # empty list
        return if $name ne $self->name;         # empty list
        return $self->value;                    # scalar
    }

    sub quote_values_as_perl {
        my $self = shift;
        my @perl_values = map {
            my $val = Data::Dumper->new([$_])->Terse(1)->Purity(1)->Useqq(1)->Sortkeys(1)->Dump;
            chomp $val;
            $val;
        } @_;
        Carp::confess("quote_values_as_perl called with multiple items in scalar context (@perl_values)")
            if @perl_values > 1 && !wantarray;
        return $perl_values[0] unless wantarray;
        return @perl_values;
    }

    # utility method to get a new composite when you only have a value object
    sub new_composite { $ContextClass->new(@_) }

} # ::BaseItem


{
    package Test::WriteVariants::Context::EnvVar;
    use strict;
    use parent -norequire, 'Test::WriteVariants::Context::BaseItem';

    # subclass representing a named environment variable

    sub get_code {
        my $self = shift;
        my $name = $self->{name};
        my @lines;
        if (defined $self->{value}) {
            my $perl_value = $self->quote_values_as_perl($self->{value});
            push @lines, sprintf('$ENV{%s} = %s;', $name, $perl_value);
            push @lines, sprintf('END { delete $ENV{%s} } # for VMS', $name);
        }
        else {
            # we treat undef to mean the ENV var should not exist in %ENV
            push @lines, sprintf('local  $ENV{%s};', $name); # preserve old value for VMS
            push @lines, sprintf('delete $ENV{%s};', $name); # delete from %ENV
        }
        return join "\n", @lines, '';
    }
}


{
    package Test::WriteVariants::Context::OurVar;
    use strict;
    use parent -norequire, 'Test::WriteVariants::Context::BaseItem';

    # subclass representing a named 'our' variable

    sub get_code {
        my $self = shift;
        my $perl_value = $self->quote_values_as_perl($self->{value});
        return sprintf 'our $%s = %s;%s', $self->{name}, $perl_value, "\n";
    }
}


{
    package Test::WriteVariants::Context::ModuleUse;
    use strict;
    use parent -norequire, 'Test::WriteVariants::Context::BaseItem';

    # subclass representing 'use $name (@$value)'

    sub get_code {
        my $self = shift;
        my @imports = $self->quote_values_as_perl(@{$self->{value}});
        return sprintf 'use %s (%s);%s', $self->{name}, join(", ", @imports), "\n";
    }
}

{
    package Test::WriteVariants::Context::MetaInfo;
    use strict;
    use parent -norequire, 'Test::WriteVariants::Context::BaseItem';

    # subclass that doesn't generate any code
    # It's just used to convey information between plugins
}

1;
