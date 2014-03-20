use strict;
use warnings;
use 5.008001;

use ExtUtils::MakeMaker;

my $mymeta_works = eval { ExtUtils::MakeMaker->VERSION('6.5707'); 1 };
my $mymeta = $mymeta_works || eval { ExtUtils::MakeMaker->VERSION('6.5702'); 1 };

my %BUILD_DEPS = (
    'Test::More' => '0.88',
    'Test::Directory' => '0.041',
);

my %RUN_DEPS = (
    'Data::Tumbler' => '0.002',
    'Module::Pluggable::Object' => '4.9',
);

my %OPT_RUN_DEPS = (
);

my %META_BITS = (
  resources => {
    homepage => 'https://metacpan.org/release/Test-WriteVariants',
    repository => {
        url  => 'git@github.com:perl5-utils/Test-WriteVariants.git',
        web  => 'https://github.com/perl5-utils/Test-WriteVariants',
        type => 'git',
    },
    bugtracker  => {
        web    => 'http://rt.cpan.org/Public/Dist/Display.html?Name=Test-WriteVariants',
        mailto => 'test-writevariants@example.com',
    },
  },
);

my %WriteMakefileArgs = (
  'NAME' => 'Test::WriteVariants',
  'VERSION_FROM'  => 'lib/Test/WriteVariants.pm',
  'ABSTRACT_FROM' => 'lib/Test/WriteVariants.pm',
  'AUTHOR' => 'Tim Bunce',

  'PREREQ_PM' => {
    %RUN_DEPS, %OPT_RUN_DEPS,
    $mymeta_works ? () : (%BUILD_DEPS),
  },

  $mymeta_works
    ? ( # BUILD_REQUIRES makes MYMETA right, requires stops META being wrong
      'BUILD_REQUIRES' => \%BUILD_DEPS,
      'META_ADD' => {
        %META_BITS,
        requires => \%RUN_DEPS,
      },
    )
    : ( # META_ADD both to get META right - only Makefile written
      'META_ADD' => {
        %META_BITS,
        requires => \%RUN_DEPS,
        build_requires => \%BUILD_DEPS,
      },
    )
  ,

  ($mymeta and !$mymeta_works) ? ( 'NO_MYMETA' => 1 ) : (),

  'LICENSE' => 'perl',
);


unless ( eval { ExtUtils::MakeMaker->VERSION('6.56') } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION('6.52') };

WriteMakefile(%WriteMakefileArgs);

exit 0;
