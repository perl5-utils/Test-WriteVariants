package Test::WriteVariants;

=head1 NAME

Test::WriteVariants - Dynamic generation of tests in nested combinations of contexts

=head1 SYNOPSIS

    my $test_writer = Test::WriteVariants->new();

    # gather set of input tests that we want to run in various contexts
    # these can come from various sources, including modules and test files
    my $input_tests = $test_writer->find_input_test_modules(
        search_path => [ 'DBI::TestCase' ]
    );

    $test_writer->write_test_variants(

        # tests we're going to run in various contexts
        input_tests => $input_tests,

        # one or more providers of variant contexts
        # these can be code refs or plugin namespaces
        variant_providers => [
            "DBI::Test::VariantDBI",
            "DBI::Test::VariantDriver",
            "DBI::Test::VariantDBD",
        ],

        # where to generate the .t files that wrap the input_tests
        output_dir => $output_dir,
    );

=head1 DESCRIPTION

NOTE: This is alpha code that's still evolving - nothing is stable.

=cut

use strict;
use warnings;
use autodie;

use File::Find;
use File::Path;
use File::Basename;
use Module::Pluggable::Object;
use Carp qw(croak confess);

use Test::WriteVariants::Context;
use Data::Tumbler;

our $VERSION = '0.003';


sub new {
    my ($class, %args) = @_;

    my $self = bless {} => $class;

    for my $attribute (qw(allow_dir_overwrite allow_file_overwrite)) {
        next unless exists $args{$attribute};
        $self->$attribute(delete $args{$attribute});
    }
    confess "Unknown $class arguments: @{[ keys %args ]}"
        if %args;

    return $self;
}


# If the output directory already exists when tumble() is called it'll
# throw an exception (and warn if it wasn't created during the run).
# Setting allow_dir_overwrite true disables this safety check.
sub allow_dir_overwrite {
    my $self = shift;
    $self->{allow_dir_overwrite} = shift if @_;
    return $self->{allow_dir_overwrite};
}

# If the test file that's about to be written already exists
# then write_output_files() will throw an exception.
# Setting allow_file_overwrite true disables this safety check.
sub allow_file_overwrite {
    my $self = shift;
    $self->{allow_file_overwrite} = shift if @_;
    return $self->{allow_file_overwrite};
}


sub write_test_variants {
    my ($self, %args) = @_;

    my $input_tests = delete $args{input_tests}
        or croak "input_tests not specified";
    my $variant_providers = delete $args{variant_providers}
        or croak "variant_providers not specified";
    my $output_dir = delete $args{output_dir}
        or croak "output_dir not specified";
    croak "write_test_variants: unknown arguments: @{[ keys %args ]}"
        if keys %args;

    croak "write_test_variants: $output_dir already exists"
        if -d $output_dir and not $self->allow_dir_overwrite;

    my $tumbler = Data::Tumbler->new(
        consumer => sub {
            my ($path, $context, $payload) = @_;
            # payload is a clone of input_tests possibly modified by providers
            $self->write_output_files($path, $context, $payload, $output_dir);
        },
        add_context => sub {
            my ($context, $item) = @_;
            return $context->new($context, $item);
        },
    );

    $tumbler->tumble(
        $self->_normalize_providers($variant_providers),
        [],
        Test::WriteVariants::Context->new(),
        $input_tests, # payload
    );

    warn "No tests written to $output_dir!\n"
        if not -d $output_dir and not $self->allow_dir_overwrite;

    return;
}



# ------

# XXX also implement a find_input_test_files - that fines .t files

sub find_input_test_modules {
    my ($self, %args) = @_;

    my $namespaces = delete $args{search_path}
        or croak "search_path not specified";
    my $test_prefix = delete $args{test_prefix};
    my $input_tests = delete $args{input_tests} || {};
    croak "find_input_test_modules: unknown arguments: @{[ keys %args ]}"
        if keys %args;

    my $edit_test_name;
    if (defined $test_prefix) {
        my $namespaces_regex = join "|", map { quotemeta($_) } @$namespaces;
        my $namespaces_qr    = qr/^($namespaces_regex)::/;
        $edit_test_name = sub { s/$namespaces_qr/$test_prefix/ };
    }

    my @test_case_modules = Module::Pluggable::Object->new(
        require => 0,
        search_path => $namespaces,
    )->plugins;

    #warn "find_input_test_modules @$namespaces: @test_case_modules";

    for my $module_name (@test_case_modules) {
        $self->add_test_module($input_tests, $module_name, $edit_test_name);
    }

    return $input_tests;
}


sub add_test_module {
    my ($self, $input_tests, $module_name, $edit_test_name) = @_;

    # map module name, without the namespace prefix, to a dir path
    local $_ = $module_name;
    $edit_test_name->() if $edit_test_name;
    s{[^\w:]+}{_}g;
    s{::}{/}g;

    $self->add_test($input_tests, $_, {
        class => $module_name,
        method => 'run_tests',
    });

    return;
}


sub add_test {
    my ($self, $input_tests, $test_name, $new_test) = @_;

    confess "Can't add test $test_name because a test with that name exists"
        if $input_tests->{ $test_name };

    $input_tests->{ $test_name } = $new_test;
    return;
}


sub _normalize_providers {
    my ($self, $input_providers) = @_;
    my @providers = @$input_providers;

    # if a provider is a namespace name instead of a code ref
    # then replace it with a code ref that uses Module::Pluggable
    # to load and run the provider classes in that namespace

    for my $provider (@providers) {
        next if ref $provider eq 'CODE';

        my @test_variant_modules = Module::Pluggable::Object->new(
            require => 1,
            on_require_error     => sub { croak "@_" },
            on_instantiate_error => sub { croak "@_" },
            search_path => [ $provider ],
        )->plugins;
        @test_variant_modules = sort @test_variant_modules;

        warn sprintf "Variant providers in %s: %s\n", $provider, join(", ", map {
            (my $n=$_) =~ s/^${provider}:://; $n
        } @test_variant_modules);

        $provider = sub {
            my ($path, $context, $tests) = @_;

            my %variants;
            # loop over several methods as a basic way of letting plugins
            # hook in either early or late if they need to
            for my $method (qw(provider_initial provider provider_final)) {
                for my $test_variant_module (@test_variant_modules) {
                    next unless $test_variant_module->can($method);
                    #warn "$test_variant_module $method...\n";
                    my $fqsn = "$test_variant_module\::$method";
                    $self->$fqsn($path, $context, $tests, \%variants);
                    #warn "$test_variant_module $method: @{[ keys %variants ]}\n";
                }
            }

            return %variants;
        };
    }

    return \@providers;
}


sub write_output_files {
    my ($self, $path, $context, $input_tests, $output_dir) = @_;

    my $base_dir_path = join "/", $output_dir, @$path;

    for my $testname (sort keys %$input_tests) {
        my $testinfo = $input_tests->{$testname};

        # note that $testname can include a subdirectory path
        $testname .= ".t" unless $testname =~ m/\.t$/;
        my $full_path = "$base_dir_path/$testname";

        warn "Writing $full_path\n";
        #warn "testinfo: @{[ %$testinfo ]}";

        my $test_script = $self->get_test_file_body($context, $testinfo);

        $self->write_file($full_path, $test_script);
    }

    return;
}


sub write_file {
    my ($self, $filepath, $content) = @_;

    croak "$filepath already exists!\n"
        if -e $filepath and not $self->allow_file_overwrite;

    my $full_dir_path = dirname($filepath);
    mkpath($full_dir_path, 0)
        unless -d $full_dir_path;

    open my $fh, ">", $filepath;
    print $fh $content;
    close $fh;

    return;
}


sub get_test_file_body {
    my ($self, $context, $testinfo) = @_;

    my @body;

    push @body, $testinfo->{prologue} || qq{#!perl\n\n};

    push @body, $context->get_code;
    push @body, "\n";

    push @body, "use lib '$testinfo->{lib}';\n\n"
        if $testinfo->{lib};

    push @body, "require '$testinfo->{require}';\n\n"
        if $testinfo->{require};

    if (my $class = $testinfo->{class}) {
        push @body, "require $class;\n\n";
        my $method = $testinfo->{method};
        push @body, "$class->$method;\n\n" if $method;
    }

    push @body, "$testinfo->{code}\n\n"
        if $testinfo->{code};

    return join "", @body;
}



1;
