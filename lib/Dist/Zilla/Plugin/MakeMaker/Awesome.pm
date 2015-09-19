package Dist::Zilla::Plugin::MakeMaker::Awesome;
# ABSTRACT: A more awesome MakeMaker plugin for L<Dist::Zilla>
# KEYWORDS: plugin installer MakeMaker Makefile.PL toolchain customize override

our $VERSION = '0.35';

use Moose;
use MooseX::Types::Moose qw< Str ArrayRef HashRef >;
use MooseX::Types::Stringlike 'Stringlike';
use namespace::autoclean;
use CPAN::Meta::Requirements 2.121; # requirements_for_module
use List::Util 1.29 qw(first pairs pairgrep);
use version;
use Path::Tiny;

extends 'Dist::Zilla::Plugin::MakeMaker' => { -version => 5.001 };
# avoid wiping out the method modifications to dump_config done by superclass
with 'Dist::Zilla::Role::FileGatherer' => { -excludes => 'dump_config' };

sub mvp_multivalue_args { qw(WriteMakefile_arg_strs test_files exe_files header_strs footer_strs) }

sub mvp_aliases {
    +{
        WriteMakefile_arg => 'WriteMakefile_arg_strs',
        test_file => 'test_files',
        exe_file => 'exe_files',
        header => 'header_strs',
        footer => 'footer_strs',
    }
}

has MakeFile_PL_template => (
    is            => 'ro',
    isa           => Stringlike,
    coerce        => 1,
    lazy          => 1,
    builder       => '_build_MakeFile_PL_template',
    documentation => "The Text::Template used to construct the ExtUtils::MakeMaker Makefile.PL",
);

sub _build_MakeFile_PL_template {
    my ($self) = @_;

    my $template = <<'TEMPLATE';
# This Makefile.PL for {{ $dist->name }} was generated by
# {{ ref $plugin }} {{ ($plugin->VERSION || '<self>')
. (ref $plugin ne 'Dist::Zilla::Plugin::MakeMaker::Awesome'
  ? "\n" . '# and Dist::Zilla::Plugin::MakeMaker::Awesome '
    . Dist::Zilla::Plugin::MakeMaker::Awesome->VERSION
  : '') }}.
# Don't edit it but the dist.ini and plugins used to construct it.

use strict;
use warnings;

{{ $perl_prereq ? qq[use $perl_prereq;] : ''; }}
use ExtUtils::MakeMaker{{ 0+$eumm_version ? ' ' . $eumm_version : '' }};

{{ $header }}

{{ $share_dir_block[0] }}

my {{ $WriteMakefileArgs }}
{{
    @$extra_args ? "%WriteMakefileArgs = (\n"
        . join('', map { "    " . $_ . ",\n" } '%WriteMakefileArgs', @$extra_args)
        . ");\n"
    : '';
}}
my {{ $fallback_prereqs }}

unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  delete $WriteMakefileArgs{TEST_REQUIRES};
  delete $WriteMakefileArgs{BUILD_REQUIRES};
  $WriteMakefileArgs{PREREQ_PM} = \%FallbackPrereqs;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);

{{ $share_dir_block[1] }}

{{ $footer }}
TEMPLATE

  return $template;
}

around BUILDARGS => sub
{
    my $orig = shift;
    my $class = shift;

    my $args = $class->$orig(@_);

    my $delimiter = delete $args->{delimiter};
    if (defined $delimiter and length($delimiter))
    {
        foreach my $arg (grep { exists $args->{$_} } qw(WriteMakefile_arg_strs header_strs footer_strs))
        {
            s/^\Q$delimiter\E// foreach @{$args->{$arg}};
        }
    }

    return $args;
};

around dump_config => sub
{
    my ($orig, $self) = @_;
    my $config = $self->$orig;

    my $data = {
        blessed($self) ne __PACKAGE__ ? ( version => $VERSION ) : (),
    };
    $config->{+__PACKAGE__} = $data if keys %$data;

    return $config;
};

has WriteMakefile_arg_strs => (
    is => 'ro', isa => ArrayRef[Str],
    traits => ['Array'],
    lazy => 1,
    default => sub { [] },
    documentation => "Additional arguments passed to ExtUtils::MakeMaker's WriteMakefile()",
);

has WriteMakefile_args => (
    isa           => HashRef,
    traits        => ['Hash'],
    handles       => {
        WriteMakefile_args => 'elements',
        delete_WriteMakefile_arg => 'delete',
        WriteMakefile_arg => 'get',
    },
    lazy          => 1,
    builder       => '_build_WriteMakefile_args',
    documentation => "The arguments passed to ExtUtils::MakeMaker's WriteMakefile()",
);

sub _build_WriteMakefile_args {
    my ($self) = @_;

    (my $name = $self->zilla->name) =~ s/-/::/g;
    my $test_files = $self->test_files;

    my $perl_prereq = $self->min_perl_version;

    my $prereqs_dump = sub {
        $self->zilla->prereqs->requirements_for(@_)
        ->clone
        ->clear_requirement('perl')
        ->as_string_hash;
    };

    my %require_prereqs = map {
        $_ => $prereqs_dump->($_, 'requires');
    } qw(configure build test runtime);

    # EUMM may soon be able to support this, but until we decide to inject a
    # higher configure-requires version, we should at least warn the user
    # https://github.com/Perl-Toolchain-Gang/ExtUtils-MakeMaker/issues/215
    foreach my $phase (qw(configure build test runtime)) {
        if (my @version_ranges = pairgrep { !version::is_lax($b) } %{ $require_prereqs{$phase} }) {
            $self->log([
                'found version range in %s prerequisites, which ExtUtils::MakeMaker cannot parse: %s %s',
                $phase, $_->[0], $_->[1]
            ]) foreach pairs @version_ranges;
        }
    }

    my @authors = @{ $self->zilla->authors };
    my $exe_files = $self->exe_files;

    my %WriteMakefile = (
        DISTNAME  => $self->zilla->name,
        NAME      => $name,
        ( AUTHOR  => @authors > 1 && ($self->eumm_version >= 6.5702 || $perl_prereq >= 5.013005)
                     ? \@authors
                     : join(q{, }, @authors) ),
        ABSTRACT  => $self->zilla->abstract,
        VERSION   => $self->zilla->version,
        LICENSE   => $self->zilla->license->meta_yml_name,
        @$exe_files ? ( EXE_FILES => [ sort @$exe_files ] ) : (),

        CONFIGURE_REQUIRES => $require_prereqs{configure},
        keys %{ $require_prereqs{build} } ? ( BUILD_REQUIRES => $require_prereqs{build} ) : (),
        keys %{ $require_prereqs{test} } ? ( TEST_REQUIRES => $require_prereqs{test} ) : (),
        PREREQ_PM          => $require_prereqs{runtime},

        test => { TESTS => join q{ }, sort @$test_files },

        $perl_prereq ? ( MIN_PERL_VERSION => $perl_prereq ) : (),
    );

    return \%WriteMakefile;
}

# overrides parent version
has eumm_version => (
    isa => 'Str',
    is  => 'rw',
    lazy => 1,
    default => sub {
        my $self = shift;
        # do not unnecessarily raise the version just for listref AUTHOR
        @{$self->zilla->authors} > 1 && $self->min_perl_version >= 5.013005
            ? '6.5702' : 0,
    },
);

has min_perl_version => (
    isa => 'Str',
    is  => 'rw',
    lazy => 1,
    builder => '_build_min_perl_version',
);

sub _build_min_perl_version
{
    my $self = shift;

    my $prereqs = $self->zilla->prereqs;
    my $perl_prereq = $prereqs->requirements_for(qw(runtime requires))
       ->clone
       ->add_requirements($prereqs->requirements_for(qw(configure requires)))
       ->add_requirements($prereqs->requirements_for(qw(build requires)))
       ->add_requirements($prereqs->requirements_for(qw(test requires)))
       ->as_string_hash->{perl};

    $perl_prereq
        ? version->parse($perl_prereq)->numify
        : 0;
}

has WriteMakefile_dump => (
    is            => 'ro',
    isa           => Stringlike,
    coerce        => 1,
    lazy          => 1,
    builder       => '_build_WriteMakefile_dump',
    documentation => "A Data::Dumper Str for using WriteMakefile_args used by MakeFile_PL_template"
);

sub _build_WriteMakefile_dump {
    my ($self) = @_;
    # Get arguments for WriteMakefile
    my %write_makefile_args = $self->WriteMakefile_args;

    return $self->_dump_as(\%write_makefile_args, '*WriteMakefileArgs');
}

has test_files => (
    is            => 'ro',
    isa           => ArrayRef[Str],
    lazy          => 1,
    builder       => '_build_test_files',
    documentation => "The glob paths given to the C<< test => { TESTS => ... } >> parameter for ExtUtils::MakeMaker's WriteMakefile() (in munged form)",
);

sub _build_test_files {
    my ($self) = @_;

    my %test_files;
    for my $file (@{ $self->zilla->files }) {
        next unless $file->name =~ m{\At/.+\.t\z};
        (my $pattern = $file->name) =~ s{/[^/]+\.t\z}{/*.t}g;

        $test_files{$pattern} = 1;
    }

    return [ keys %test_files ];
}

has exe_files => (
    is            => 'ro',
    isa           => ArrayRef[Str],
    lazy          => 1,
    builder       => '_build_exe_files',
    documentation => "The test directories given to ExtUtils::MakeMaker's EXE_FILES (in munged form)",
);

sub _build_exe_files {
    my ($self) = @_;

    my @exe_files = map { $_->name } @{ $self->zilla->find_files(':ExecFiles') };

    return \@exe_files;
}

has share_dir_block => (
    is            => 'ro',
    isa           => ArrayRef[Str],
    auto_deref    => 1,
    lazy          => 1,
    builder       => '_build_share_dir_block',
    documentation => "The share dir block used in `MakeFile_PL_template'",
);

sub _build_share_dir_block {
    my ($self) = @_;

    my @share_dir_block = (q{}, q{});

    my $share_dir_map = $self->zilla->_share_dir_map;
    if ( keys %$share_dir_map ) {
        # split in two to foil CPANTS prereq_matches_use
        my $preamble = qq{use File::Shar}.qq{eDir::Install;\n};
        if ( my $dist_share_dir = $share_dir_map->{dist} ) {
            $dist_share_dir = quotemeta $dist_share_dir;
            $preamble .= qq{install_share dist => "$dist_share_dir";\n};
        }

        if ( my $mod_map = $share_dir_map->{module} ) {
            for my $mod ( keys %$mod_map ) {
                my $mod_share_dir = quotemeta $mod_map->{$mod};
                $preamble .= qq{install_share module => "$mod", "$mod_share_dir";\n};
            }
        }
        @share_dir_block = (
            $preamble,
            qq{\{\npackage\nMY;\nuse File::ShareDir::Install qw(postamble);\n\}\n},

        );
    }

    return \@share_dir_block;
}

has header_strs => (
    is => 'ro', isa => ArrayRef[Str],
    traits => ['Array'],
    lazy => 1,
    default => sub { [] },
    documentation => "Additional code lines to include at the beginning of Makefile.PL",
);

has header_file => (
    is => 'ro', isa => Str,
    documentation => 'Additional header content to include from a file',
);

has header => (
    is            => 'ro',
    isa           => Str,
    lazy          => 1,
    builder       => '_build_header',
    documentation => "A string included at the beginning of Makefile.PL",
);

sub _build_header {
    my $self = shift;
    join "\n",
        @{$self->header_strs},
        ( $self->header_file ? path($self->header_file)->slurp_utf8 : () );
}

has footer_strs => (
    is => 'ro', isa => ArrayRef[Str],
    traits => ['Array'],
    lazy => 1,
    default => sub { [] },
    documentation => "Additional code lines to include at the end of Makefile.PL",
);

has footer_file => (
    is => 'ro', isa => Str,
    documentation => 'Additional footer content to include from a file',
);

has footer => (
    is            => 'ro',
    isa           => Str,
    lazy          => 1,
    builder       => '_build_footer',
    documentation => "A string included at the end of Makefile.PL",
);

sub _build_footer {
    my $self = shift;
    join "\n",
        @{$self->footer_strs},
        ( $self->footer_file ? path($self->footer_file)->slurp_utf8 : () );
}

sub register_prereqs {
    my ($self) = @_;

    $self->zilla->register_prereqs(
        { phase => 'configure' },
        'ExtUtils::MakeMaker' => $self->eumm_version || 0,
    );

    return unless keys %{ $self->zilla->_share_dir_map };

    $self->zilla->register_prereqs(
        { phase => 'configure' },
        'File::ShareDir::Install' => 0.03,
    );

    return {};
}

sub gather_files
{
    my $self = shift;

    require Dist::Zilla::File::InMemory;
    my $file = Dist::Zilla::File::InMemory->new({
        name    => 'Makefile.PL',
        content => $self->MakeFile_PL_template,     # template evaluated later
    });

    $self->add_file($file);
    return;
}

sub setup_installer
{
    my $self = shift;

    $self->log_debug('setup_installer');

    ## Sanity checks
    $self->log_fatal("can't install files with whitespace in their names")
        if grep { /\s/ } @{$self->exe_files};

    my $perl_prereq = $self->WriteMakefile_arg('MIN_PERL_VERSION');

    # file was already created; find it and fill in the content
    my $file = first { $_->name eq 'Makefile.PL' } @{$self->zilla->files};
    $self->log_debug([ 'updating contents of Makefile.PL in memory' ]);

    $self->log_fatal('Makefile.PL has vanished from the distribution! Did you [PruneFiles] the file after it was gathered?'
            . "\n" . '(instead, try [GatherDir] exclude_filename = Makefile.PL)')
        if not $file;

    my $content = $self->fill_in_string(
        $file->content,
        {
            dist              => \($self->zilla),
            plugin            => \$self,
            eumm_version      => \($self->eumm_version),
            perl_prereq       => \$perl_prereq,
            share_dir_block   => [ $self->share_dir_block ],
            fallback_prereqs  => \($self->fallback_prereq_pm),
            WriteMakefileArgs => \($self->WriteMakefile_dump),
            extra_args        => \($self->WriteMakefile_arg_strs),
            header            => \$self->header,
            footer            => \$self->footer,
        },
    );

    $content =~ s/\n{3,}/\n\n/g;
    $content =~ s/\n+\z/\n/;

    $file->content($content);
    return;
}

__PACKAGE__->meta->make_immutable;

__END__

=pod

=head1 SYNOPSIS

In your F<dist.ini>:

    [MakeMaker::Awesome]
    WriteMakefile_arg = CCFLAGS => `pkg-config --cflags libpng`
    WriteMakefile_arg = LIBS => [ `pkg-config --libs libpng` ]
    header = die 'Unsupported OS' if $^O eq 'MSWin32';
    delimiter = |
    footer = |package MY;
    footer = |sub postamble {
    footer = |    my $self = shift;
    footer = |    return $self->SUPER::postamble . "\n\nfoo: bar\n\t$(CP) bar foo\n";
    footer = |}

or:

    ;; Replace [MakeMaker]
    ;[MakeMaker]
    [=inc::MyMakeMaker]

=head1 DESCRIPTION

L<Dist::Zilla>'s L<MakeMaker|Dist::Zilla::Plugin::MakeMaker> plugin is
limited, if you want to stray from the marked path and do something
that would normally be done in a C<package MY> section or otherwise
run custom code in your F<Makefile.PL> you're out of luck.

This plugin is 100% compatible with L<Dist::Zilla::Plugin::MakeMaker> -- we
add additional customization hooks by subclassing it.

=head1 CONFIGURATION OPTIONS

Many features can be accessed directly via F<dist.ini>, by setting options.
For options where you expect a multi-line string to be inserted into
F<Makefile.PL>, use the config option more than once, setting each line
separately.

=head2 WriteMakefile_arg

A string, which evaluates to an even-numbered list, which will be included in the call to
C<WriteMakefile>.  Any code is legal that can be inserted into a list of other
key-value pairs, for example:

    [MakeMaker::Awesome]
    WriteMakefile_arg = ( $^O eq 'solaris' ? ( CCFLAGS => '-Wall' ) : ())

Can be used more than once.
Available since version 0.21.

=for stopwords DynamicPrereqs

Note: you (intentionally) cannot use this mechanism for specifying dynamic
prerequisites, as previous occurrences of a top-level key will be overwritten
(additionally, you cannot set the fallback prereqs from here). You should take
a look at L<[DynamicPrereqs]|Dist::Zilla::Plugin::DynamicPrereqs> for this.

=head2 header

A line of code which is included near the top of F<Makefile.PL>.  Can be used more than once.
Available since version 0.26.

=head2 header_file

The name of a file in the source tree (does not need to be gathered in the
build) whose content is inserted near the top of F<Makefile.PL>.
Available since version 0.35.

=head2 footer

A line of code which is included at the bottom of F<Makefile.PL>.  Can be used more than once.
Available since version 0.26.

=head2 footer_file

The name of a file in the source tree (does not need to be gathered in the
build) whose content is inserted at the bottom of F<Makefile.PL>.
Available since version 0.35.

=head2 delimiter

A string, usually a single character, which is stripped from the beginning of
all C<WriteMakefile_arg>, C<header>, and C<footer> lines. This is because the
INI file format strips all leading whitespace from option values, so including
this character at the front allows you to use leading whitespace in an option
string.  This is crucial for the formatting of F<Makefile>s, but a nice thing
to have when inserting any block of code.

Available since version 0.27.

=head2 test_file

A glob path given to the C<< test => { TESTS => ... } >> parameter for
L<ExtUtils::MakeMaker/WriteMakefile>. Can be used more than once.
Defaults to F<.t> files under F<t/>.  B<NOT> a directory name, despite the name.

Available since version 0.21.

=head2 exe_file

The file given to the C<EXE_FILES> parameter for
L<ExtUtils::MakeMaker/WriteMakefile>. Can be used more than once.
Defaults to using data from C<:ExecDir> plugins.

Available since version 0.21.

=head1 SUBCLASSING

You can further customize the content of F<Makefile.PL> by subclassing this plugin,
L<Dist::Zilla::Plugin::MakeMaker::Awesome>.

As an example, adding a C<package MY> section to your
F<Makefile.PL>:

In your F<dist.ini>:

    [=inc::MyDistMakeMaker / MyDistMakeMaker]

Then in your F<inc/MyDistMakeMaker.pm>, real example from L<Hailo>
(which has C<[=inc::HailoMakeMaker / HailoMakeMaker]> in its
F<dist.ini>):

    package inc::HailoMakeMaker;
    use Moose;

    extends 'Dist::Zilla::Plugin::MakeMaker::Awesome';

    override _build_MakeFile_PL_template => sub {
        my ($self) = @_;
        my $template = super();

        $template .= <<'TEMPLATE';
    package MY;

    sub test {
        my $inherited = shift->SUPER::test(@_);

        # Run tests with Moose and Mouse
        $inherited =~ s/^test_dynamic :: pure_all\n\t(.*?)\n/test_dynamic :: pure_all\n\tANY_MOOSE=Mouse $1\n\tANY_MOOSE=Moose $1\n/m;

        return $inherited;
    }
    TEMPLATE

        return $template;
    };

    __PACKAGE__->meta->make_immutable;

=for stopwords distro

Or maybe you're writing an XS distro and want to pass custom arguments
to C<WriteMakefile()>, here's an example of adding a C<LIBS> argument
in L<re::engine::PCRE> (note that you can also achieve this without
subclassing, by passing the L</WriteMakefile_arg> option):

    package inc::PCREMakeMaker;
    use Moose;

    extends 'Dist::Zilla::Plugin::MakeMaker::Awesome';

    override _build_WriteMakefile_args => sub { +{
        # Add LIBS => to WriteMakefile() args
        %{ super() },
        LIBS => [ '-lpcre' ],
    } };

    __PACKAGE__->meta->make_immutable;

And another example from L<re::engine::Plan9>, which determines the arguments
dynamically at build time:

    package inc::Plan9MakeMaker;
    use Moose;

    extends 'Dist::Zilla::Plugin::MakeMaker::Awesome';

    override _build_WriteMakefile_args => sub {
        my ($self) = @_;

        our @DIR = qw(libutf libfmt libregexp);
        our @OBJ = map { s/\.c$/.o/; $_ }
                   grep { ! /test/ }
                   glob "lib*/*.c";

        return +{
            %{ super() },
            DIR           => [ @DIR ],
            INC           => join(' ', map { "-I$_" } @DIR),

            # This used to be '-shared lib*/*.o' but that doesn't work on Win32
            LDDLFLAGS     => "-shared @OBJ",
        };
    };

    __PACKAGE__->meta->make_immutable;

If you have custom code in your L<ExtUtils::MakeMaker>-based
F<Makefile.PL> that L<Dist::Zilla> can't replace via its default
facilities you'll be able to replace it by using this module.

Even if your F<Makefile.PL> isn't L<ExtUtils::MakeMaker>-based you
should be able to override it. You'll just have to provide a new
L</"_build_MakeFile_PL_template">.

=for stopwords overridable

=head2 OVERRIDABLE METHODS

These are the methods you can currently C<override> or method-modify in your
custom F<inc/> module. The work that this module does is entirely done in
small modular methods that can be overridden in your subclass. Here are
some of the highlights:

=for Pod::Coverage mvp_multivalue_args mvp_aliases

=head3 _build_MakeFile_PL_template

Returns a L<Text::Template> string used to construct the F<Makefile.PL>.

If you need to insert some additional code to the beginning or end of
F<Makefile.PL> (without modifying the existing content, you should use an
C<around> method modifier, something like this:

    around _build_MakeFile_PL_template => sub {
        my $orig = shift;
        my $self = shift;

        my $NEW_CONTENT = ...;

        # insert new content near the beginning of the file, preserving the
        # existing header content
        my $string = $self->$orig(@_);
        $string =~ m/use warnings;\n\n/g;
        return substr($string, 0, pos($string)) . $NEW_CONTENT . substr($string, pos($string));
    };

=head3 _build_WriteMakefile_args

A C<HashRef> of arguments that will be passed to
L<ExtUtils::MakeMaker>'s C<WriteMakefile> function.

=head3 _build_WriteMakefile_dump

Takes the return value of L</"_build_WriteMakefile_args"> and
constructs a L<Str> that will be included in the F<Makefile.PL> by
L</"_build_MakeFile_PL_template">.

=head3 _build_header

A C<Str> of code that will be included near the top of F<Makefile.PL>.

=head3 _build_footer

A C<Str> of code that will be included at the bottom of F<Makefile.PL>.

=head3 _build_test_files

The glob paths given to the C<< test => { TESTS => ... } >> parameter for
L<ExtUtils::MakeMaker/WriteMakefile>.  Defaults to F<.t> files under F<t/>.
B<NOT> directories, despite the name.

=head3 _build_exe_files

The files given to the C<EXE_FILES> parameter for
L<ExtUtils::MakeMaker/WriteMakefile>.
Defaults to using data from C<:ExecDir> plugins.

=head3 _build_min_perl_version

Extracts from the distribution prerequisite object the minimum version of perl
required; used for the C<MIN_PERL_VERSION> parameter for
L<ExtUtils::MakeMaker/WriteMakefile>.

=head3 register_prereqs

=head3 gather_files

=head3 setup_installer

=for stopwords dirs

The test/bin/share dirs and exe_files. These will all be passed to
F</"_build_WriteMakefile_args"> later.

=head3 _build_share_dir_block

=for stopwords sharedir

An C<ArrayRef[Str]> with two elements to be used by
L</"_build_MakeFile_PL_template">. The first will declare your
L<sharedir|File::ShareDir::Install> and the second will add a magic
C<package MY> section to install it. Deep magic.

=head2 OTHER

The main entry point is C<setup_installer> via the
L<Dist::Zilla::Role::InstallTool> role. There are also other magic
Dist::Zilla roles, check the source for more info.

=head1 DIAGNOSTICS

=over

=item attempt to add F<Makefile.PL> multiple times

This error from L<Dist::Zilla> means that you've used both
C<[MakeMaker]> and C<[MakeMaker::Awesome]>. You've either included
C<MakeMaker> directly in F<dist.ini>, or you have plugin bundle that
includes it. See L<@Filter|Dist::Zilla::PluginBundle::Filter> for how
to filter it out.

=back

=head1 LIMITATIONS

=for stopwords INI

This plugin would suck less if L<Dist::Zilla> didn't use a INI-based
config system so you could add stuff like this in your main
configuration file like you can with L<Module::Install>.

The F<.ini> file format can only support key-value pairs whereas any
complex use of L<ExtUtils::MakeMaker> requires running custom Perl
code and passing complex data structures to C<WriteMakefile>.

=head1 AFTERWORD

     ________________________
    < everything is AWESOME! >
     ------------------------
        \                                  ___-------___
         \                             _-~~             ~~-_
          \                         _-~                    /~-_
                 /^\__/^\         /~  \                   /    \
               /|  O|| O|        /      \_______________/        \
              | |___||__|      /       /                \          \
              |          \    /      /                    \          \
              |   (_______) /______/                        \_________ \
              |         / /         \                      /            \
               \         \^\\         \                  /               \     /
                 \         ||           \______________/      _-_       //\__//
                   \       ||------_-~~-_ ------------- \ --/~   ~\    || __/
                     ~-----||====/~     |==================|       |/~~~~~
                      (_(__/  ./     /                    \_\      \.
                             (_(___/                         \_____)_)


=cut
