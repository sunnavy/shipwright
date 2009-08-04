package Shipwright::Backend::SVK;

use warnings;
use strict;
use Carp;
use File::Spec::Functions qw/catfile/;
use Shipwright::Util;
use File::Temp qw/tempdir/;
use File::Copy::Recursive qw/rcopy/;
use File::Path qw/remove_tree/;

our %REQUIRE_OPTIONS = ( import => [qw/source/] );

use base qw/Shipwright::Backend::Base/;

=head1 NAME

Shipwright::Backend::SVK - SVK repository backend

=head1 DESCRIPTION

This module implements an SVK repository backend for Shipwright.

=head1 METHODS

=over

=item initialize

initialize a project.

=cut

sub initialize {
    my $self = shift;
    my $dir  = $self->SUPER::initialize(@_);

    $self->delete;    # clean repository in case it exists
    $self->import(
        source      => $dir,
        _initialize => 1,
        comment     => 'created project',
    );
}

sub _svnroot {
    my $self = shift;
    return $self->{svnroot} if $self->{svnroot};
    my $depotmap = Shipwright::Util->run( [ $ENV{'SHIPWRIGHT_SVK'} => depotmap => '--list' ] );
    $depotmap =~ s{\A.*?^(?=/)}{}sm;
    while ($depotmap =~ /^(\S*)\s+(.*?)$/gm) {
        my ($depot, $svnroot) = ($1, $2);
        if ($self->repository =~ /^$depot(.*)/) {
            return $self->{svnroot} = "file://$svnroot/$1";
        }
    }
    croak "Can't find determine underlying SVN repository for ". $self->repository;
}

# a cmd generating factory
sub _cmd {
    my $self = shift;
    my $type = shift;
    my %args = @_;
    $args{path}    ||= '';
    $args{comment} ||= '';

    for ( @{ $REQUIRE_OPTIONS{$type} } ) {
        croak "$type need option $_" unless $args{$_};
    }

    my @cmd;

    if ( $type eq 'checkout' ) {
        if ( $args{detach} ) {
            @cmd = [ $ENV{'SHIPWRIGHT_SVK'}, 'checkout', '-d', $args{target} ];
        }
        else {
            @cmd = [
                $ENV{'SHIPWRIGHT_SVK'},                           'checkout',
                $self->repository . $args{path}, $args{target}
            ];
        }
    }
    elsif ( $type eq 'export' ) {
        @cmd = (
            [
                $ENV{'SHIPWRIGHT_SVN'},                           'export',
                $self->_svnroot . $args{path}, $args{target}
            ],
        );
    }
    elsif ( $type eq 'list' ) {
        @cmd = [ $ENV{'SHIPWRIGHT_SVN'}, 'list', $self->_svnroot . $args{path} ];
    }
    elsif ( $type eq 'import' ) {
        if ( $args{_initialize} ) {
            @cmd = [
                $ENV{'SHIPWRIGHT_SVK'}, 'import', $args{source},
                $self->repository . ( $args{path} || '' ),
                '-m', $args{comment},
            ];
        }
        elsif ( $args{_extra_tests} ) {
            @cmd = [
                $ENV{'SHIPWRIGHT_SVK'},         'import',
                $args{source}, $self->repository . '/t/extra',
                '-m',          $args{comment},
            ];
        }
        else {
            my ( $path, $source );
            if ( $args{build_script} ) {
                $path   = "/scripts/$args{name}";
                $source = $args{build_script};
            }
            else {
                $path =
                  $self->has_branch_support
                  ? "/sources/$args{name}/$args{as}"
                  : "/dists/$args{name}";
                $source = $args{source};
            }

            if ( $self->info( path => $path ) ) {
                my $tmp_dir =
                  tempdir( 'shipwright_backend_svk_XXXXXX', CLEANUP => 1, TMPDIR => 1 );
                @cmd = (
                    sub { remove_tree( $tmp_dir ) },
                    [ $ENV{'SHIPWRIGHT_SVK'}, 'checkout', $self->repository . $path, $tmp_dir ],
                    sub { remove_tree( $tmp_dir ) },
                    sub { rcopy( $source, $tmp_dir ) },
                    [
                        $ENV{'SHIPWRIGHT_SVK'},      'commit',
                        '--import', $tmp_dir,
                        '-m',       $args{comment}
                    ],
                    [ $ENV{'SHIPWRIGHT_SVK'}, 'checkout', '-d', $tmp_dir ],
                );
            }
            else {
                @cmd = [
                    $ENV{'SHIPWRIGHT_SVK'},   'import',
                    $source, $self->repository . $path,
                    '-m',    $args{comment},
                ];
            }
        }
    }
    elsif ( $type eq 'commit' ) {
        @cmd = [
            $ENV{'SHIPWRIGHT_SVK'},
            'commit',
            (
                $args{import}
                ? '--import'
                : ()
            ),
            '-m',
            $args{comment},
            $args{path}
        ];
    }
    elsif ( $type eq 'delete' ) {
        @cmd = [
            $ENV{'SHIPWRIGHT_SVK'}, 'delete', '-m',
            'delete repository',
            $self->repository . $args{path},
        ];
    }
    elsif ( $type eq 'move' ) {
        @cmd = [
            $ENV{'SHIPWRIGHT_SVK'},
            'move',
            '-m',
            "move $args{path} to $args{new_path}",
            $self->repository . $args{path},
            $self->repository . $args{new_path}
        ];
    }
    elsif ( $type eq 'info' ) {
        @cmd = [ $ENV{'SHIPWRIGHT_SVK'}, 'info', $self->repository . $args{path} ];
    }
    elsif ( $type eq 'cat' ) {
        @cmd = [ $ENV{'SHIPWRIGHT_SVN'}, 'cat', $self->_svnroot . $args{path} ];
    }
    else {
        croak "invalid command: $type";
    }

    return @cmd;
}

sub _yml {
    my $self = shift;
    my $path = shift;
    my $yml  = shift;

    $path = '/' . $path unless $path =~ m{^/};

    my ($f) = $path =~ m{.*/(.*)$};

    if ($yml) {
        my $dir =
          tempdir( 'shipwright_backend_svk_XXXXXX', CLEANUP => 1, TMPDIR => 1 );
        my $file = catfile( $dir, $f );

        $self->checkout( path => $path, target => $file );

        Shipwright::Util::DumpFile( $file, $yml );
        $self->commit( path => $file, comment => "updated $path" );
        $self->checkout( detach => 1, target => $file );
    }
    else {
        my ($out) =
          Shipwright::Util->run( [ $ENV{'SHIPWRIGHT_SVK'}, 'cat', $self->repository . $path ] );
        return Shipwright::Util::Load($out);
    }
}

=item info

a wrapper around svk's info command.

=cut

sub info {
    my $self = shift;
    my ( $info, $err ) = $self->SUPER::info(@_);

    if (wantarray) {
        return $info, $err;
    }
    else {
        return if $info =~ /not exist|not a checkout path/;
        return $info;
    }
}

=item check_repository

check if the given repository is valid.

=cut

sub check_repository {
    my $self = shift;
    my %args = @_;

    if ( $args{action} eq 'create' ) {

        # svk always has //
        return 1 if $self->repository =~ m{^//};

        if ( $self->repository =~ m{^(/[^/]+/)} ) {
            my $ori = $self->repository;
            $self->repository($1);

            my $info = $self->info;

            # revert back
            $self->repository($ori);

            return 1 if $info;
        }

    }
    else {
        return $self->SUPER::check_repository(@_);
    }
    return;
}

sub _update_file {
    my $self   = shift;
    my $path   = shift;
    my $latest = shift;

    my $dir =
      tempdir( 'shipwright_backend_svk_XXXXXX', CLEANUP => 1, TMPDIR => 1 );
    my $file = catfile( $dir, $path );

    $self->checkout(
        path   => $path,
        target => $file,
    );

    rcopy( $latest, $file ) or confess "can't copy $latest to $file: $!";
    $self->commit(
        path    => $file,
        comment => "updated $path",
    );
    $self->checkout( detach => 1, target => $file );
}

sub _update_dir {
    my $self   = shift;
    my $path   = shift;
    my $latest = shift;

    my $dir =
      tempdir( 'shipwright_backend_svk_XXXXXX', CLEANUP => 1, TMPDIR => 1 );
    rmdir $dir;

    $self->checkout(
        path   => $path,
        target => $dir,
    );

    rcopy( $latest, $dir ) or confess "can't copy $latest to $dir: $!";
    $self->commit(
        path    => $dir,
        comment => "updated $path",
        import  => 1,
    );
    $self->checkout( detach => 1, target => $dir );
}

=back

=cut

1;

__END__

=head1 AUTHORS

sunnavy  C<< <sunnavy@bestpractical.com> >>

=head1 LICENCE AND COPYRIGHT

Shipwright is Copyright 2007-2009 Best Practical Solutions, LLC.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
