# (C) 2010 Endevver LLC. All Rights Reserved.
# This code is licensed under the GPL v2.

package MT::Theme::Exporter;

use File::Basename qw( basename dirname );
use File::Copy::Recursive qw(dircopy);
use File::Path;
use File::Spec;
use MT;
use MT::FileMgr;
use MT::Util qw( dirify );
use YAML::Tiny;

use Carp;
use strict;
use vars qw( @EXPORT_OK );

# We are exporting functions
use base qw/Exporter/;
# Export list - to allow fine tuning of export table
@EXPORT_OK = qw( export );

sub DESTROY { }

$SIG{INT} = sub { die "Interrupted\n"; };

$| = 1;    # autoflush

sub new {
    my $class  = shift;
    my $params = shift;
    my $self   = {};
    foreach my $prop (qw/ id key pack_name pack_description pack_version dryrun verbose logger app /) {
        if ( exists $params->{$prop} ) {
            $self->{$prop} = $params->{$prop};
        }
    }
    $self->{'app'}              ||= MT->new() or die MT->errstr;
    $self->{'logger'}           ||= sub { },
    $self->{'pack_name'}        ||= 'My Theme Pack';
    $self->{'pack_description'} ||= 'A collection of themes exported by Endevver\'s theme exporter.';
    $self->{'pack_version'}     ||= '1.0';
    $self->{'id'}               ||= dirify( $self->{'pack_name'} );
    $self->{'key'}              ||= dirify( $self->{'pack_name'} );
    $self->{'basedir'}          ||= $self->{'key'} . "-" . $self->{'pack_version'};
    $self->{'fmgr'}             ||= MT::FileMgr->new('Local');

    $self->{'yaml'} = YAML::Tiny->new;
    $self->{'yaml'}->[0] = {
        id            => $self->{'id'},
        key           => $self->{'key'},
        name          => $self->{'pack_name'},
        description   => $self->{'pack_description'},
    };                
    # End init code


    bless $self, $class;
    return $self;
}

sub write {
    my $self = shift;
    my $filepath = File::Spec->catfile( 
        $self->{'basedir'}, 'plugins', $self->{'key'}, 'config.yaml' );
    $self->_debug("  - Writing config.yaml file $filepath");
    unless ( $self->_is_dryrun() ) {
        $self->{'yaml'}->write($filepath) or die $self->{'yaml'}->errstr;            
    }
}

sub export {
    my $self = shift;
    my ($options) = @_;

    my $blog_id = $options->{'blog_id'};
    my $name    = $options->{'name'};
    my $static  = $options->{'static'};
    my $ts_id   = $options->{'id'};
    $ts_id ||= dirify($name);

    # Initialize the data structure for the current template set
    # we are exporting.
    $self->{'yaml'}->[0]->{'template_sets'} = {
        $ts_id => {
            label     => $name,
            base_path => File::Spec->catdir( 'templates', $ts_id )
        }
    };

    # Create a shortcut to our template set node, this is in essense a cursor
    # pointing to the current template set being exported.
    $self->{'current_ts'} = $self->{'yaml'}->[0]->{'template_sets'}->{ $ts_id };
    
    # Set the current template path. Each theme will live in its own subdirectory
    # under the theme pack's 'templates' directory.
    my $templates_path
        = File::Spec->catdir( $self->{'basedir'}, 
                              'plugins', $self->{'key'}, 'templates', $ts_id );

    $self->{'fmgr'}->exists($templates_path) or $self->{'fmgr'}->mkpath($templates_path)
        or die sprintf("Could not make path %s: %s\n",
                       $templates_path, $self->{'fmgr'}->errstr);

    # TODO - static files need utilize config assistant's new static file structure
    my $from = File::Spec->catdir( _static_file_path($self->{'app'}) , $static );
    if (-e $from) { 
        my $to   = File::Spec->catdir( $self->{'basedir'}, 'mt-static', $static );
        $self->_debug( 'Copying static files from ' . $from . ' to ' . $to );
        $self->{'fmgr'}->mkpath( $to );
        dircopy( $from, $to );
    }

    $self->_debug( 'Exporting templates from blog #' . $blog_id );

    # What type of export are we running?
    # Blog-level or global templates?
    # TODO - automatically export global templates, but only the ones the theme uses
    my $set_type = $blog_id ? 'blog' : 'global';

    # Process the set_type templates as well as those which
    # can be found as either global or blog-level templates

    my $cfg = $self->_process_templates( $blog_id, $ts_id, $_ )
        foreach map { @{ _template_group($blog_id, $_) } } ( $set_type, 'all' );

    # Store the provided configuration data in the node
    # corresponding to the template's type and basename.
    # REMOVED because it is in _process_templates
    # $self->{'current_ts'}->{templates}->{ $cfg->{type} }->{ $cfg->{basename} }
    #   = $cfg->{data};
    
    $self->_process_export_queue();
}

=head2

This utility method processes all of the templates that have accrued on the 
"export queue" assembled during the export process. The export queue consists
of global templates that need to be exported in order for a theme to operate
properly.

=cut
sub _process_export_queue {
    my $self = shift;
    my %seen;
    foreach my $inc (sort { $a->{id} <=> $b->{id} } @{ $self->{'export_queue'} }) {
        # FIXME: this should be de-duped much earlier in the process
        unless ( $seen{ $inc->{id} } ) {
            print "Processing " . $inc->{name} . " (".$inc->{id}.") off of export queue.\n";

            # FIXME: this is hard coded to global templates based upon the assumption that
            #        only global templates will be automatically included
            # my $cfg = $self->_process_templates( $inc->{'blog_id'}, 'global', {
            my $cfg = $self->_process_templates( 0, 'global', {
                type      => 'module',
                basename  => dirify( $inc->{'name'} ),
                load_args => [ { blog_id => 0, id => $inc->{'id'} } ]
            });

            $seen{ $inc->{id} } = 1;
        }
    }
}

=head2

This helper function helps to build the terms and args hash map for
querying the MT database for templates.

=cut
sub _template_group {
    my ($blog_id, $key) = @_;

    my %blog_id = (blog_id => $blog_id);
    
    my %template_groups = (
        #
        # Blog-level templates
        #
        blog   => [
            {
                type      => 'index',
                load_args => {  %blog_id, type => 'index'  },
                config    => sub { { outfile    => $_[0]->outfile,
                                     rebuild_me => $_[0]->rebuild_me } },
            },    
            {
                type      => 'archive',
                config    => \&_templatemap_config,
                load_args => [
                         { %blog_id, type => 'archive' }     => -or =>
                         { %blog_id, type => 'individual' }  => -or =>
                         { %blog_id, type => 'page' },
                 ],
            },
            {
                type      => 'system',
                basename  => sub { $_[0]->type },
                load_args => [
                    { %blog_id, type => 'popup_image' }      => -or =>
                    { %blog_id, type => 'dynamic_error' }    => -or =>
                    { %blog_id, type => 'search_results' }   => -or =>
                    { %blog_id, type => 'comment_preview' }  => -or =>
                    { %blog_id, type => 'comment_response' }
                ],
            }
        ],
        #
        # Global shared templates
        #
        global => [
            {
                type      => 'system',
                basename  => sub { $_[0]->type },
                load_args => [
                    { %blog_id, type => 'login_form' }          => -or =>
                    { %blog_id, type => 'profile_view' }        => -or =>
                    { %blog_id, type => 'profile_feed' }        => -or =>
                    { %blog_id, type => 'register_form' }       => -or =>
                    { %blog_id, type => 'profile_error' }       => -or =>
                    { %blog_id, type => 'profile_edit_form' }   => -or =>
                    { %blog_id, type => 'password_reset_form' } => -or =>
                    { %blog_id, type => 'register_confirmation' }
                ],
            },
            {
                type      => 'email',
                load_args => { %blog_id, type => 'email' },
            },
        ],
        #
        # Templates found in both the global shared and blog sets
        #
        all    => [
            {
                type      => 'module',
                load_args => { %blog_id, type => 'custom' },
            },
            {
                type      => 'widget',
                load_args => {  %blog_id, type => 'widget' },
            },
            {
                type      => 'widgetset',
                load_args => { %blog_id, type => 'widgetset' },
            },    
        ],
    );

    # return entire hash is a specific subset of the hash was not requested
    return \%template_groups unless defined $key;
    
    die sprintf('Unknown template group "%s"', $key)
        unless exists $template_groups{$key};

    return $template_groups{$key};
}

sub _process_templates {
    my $self = shift;
    my ( $blog_id, $ts_id, $args ) = @_;
    $args ||= {};
    if (!$args->{load_args}) {
        require Data::Dumper;
        croak 'process_templates called with no load_args argument: '
             . Data::Dumper::Dumper($args);
    }
    my $iter = MT->model('template')->load_iter($args->{load_args});

    while (my $t = $iter->()) {
        # use Data::Dumper;
        # $self->_debug(Dumper($t));
        $self->_debug( sprintf '  - Creating %s: %s',
            $args->{type}, $t->name );

        my $basename ||= $t->identifier || _create_basename($t->name);

        # Resolve the basename in case its a code ref
        if ($basename and 'CODE' eq ref($basename)) {
            $basename = $basename->($t);
        }
        else {
            # If a basename is not provided, create it using the
            # identifier or the template name
            $basename ||= $t->identifier || _create_basename($t->name);
        }
        
        # Trim the basename to 50 characters
        $basename = substr($basename, 0, 50);

        my $includes = $self->_find_includes( $t );
        foreach my $i (@$includes) {
            push @{$self->{'export_queue'}},$i
                if ($i->{blog_id} eq 0);
                # TODO - for now it might be best if this only processed 
                #        global templates?
                # if ($i->{blog_id} ne $blog_id);
        }

        # Write the template text out to a file within the plugin envelope
        if ( $self->_write_tmpl( $t, $ts_id, $args->{type}, $basename )) {

            # Using the template in context, compile the YAML config
            my $cfg = { label    => $t->name,
                        filename => File::Spec->catfile($args->{type},
                                                        $basename.'.mtml') };

            # The "config" attribute can be either a code or hash reference
            if ( 'CODE' eq ref($args->{config}) ) {
                $cfg = { %$cfg,  %{ $args->{config}->($t) } };
            }
            elsif ( 'HASH' eq ref($args->{config}) ) {
                $cfg = { %$cfg,  %{ $args->{config} } };                
            }

            # Store the provided configuration data in the node
            # corresponding to the template's type and basename.
            if ($blog_id == 0) {
                unless ($self->{'yaml'}->[0]->{'default_templates'}->{'base_path'}) {
                    $self->{'yaml'}->[0]->{'default_templates'}->{'base_path'} = 'templates/global';
                }
                $self->{'yaml'}->[0]->{'default_templates'}->{ 'global:'.$args->{'type'} }->{ $basename } 
                   = $cfg;
            } else {
                $self->{'current_ts'}->{'templates'}->{ $args->{'type'} }->{ $basename } 
                   = $cfg; 
            }
        }
    }
}

sub _templatemap_config {
    my $t = shift;

    my $mappings;
    my @maps = MT->model('templatemap')->load( { 'template_id' => $t->id, } );
    for my $map (@maps) {
        my $type = lc( $map->archive_type );
        $type =~ s/ /-/g;
        $mappings->{$type} = {
                    archive_type => $map->archive_type,
                    preferred    => $map->is_preferred,
                    $map->file_template
                    && $map->file_template ne '~'
                    && $map->file_template ne ''
                        ? ( file_template => $map->file_template )
                        : (),
          };
    }

    return  { mappings => $mappings };
}

sub _create_basename {
    my $name = shift;
    require MT::Util;
    my $id = MT::Util::dirify($name)
        or die sprintf 'Could not create basename for template "%s"', $name;
    $id;
}

sub _is_dryrun {
    my $self = shift;
    return 0 unless $self->{'dryrun'};
    $self->_debug("\t-- Previous action blocked for dry-run test");
    1;
}

sub _debug {
    my $self = shift;
    $self->{'logger'}( $_[0] . "\n") if $self->{'verbose'} || $self->{'dryrun'};
}

sub _static_file_path {
    my ($ctx) = @_;
    my $cfg = $ctx->{cfg};
    my $path = $cfg->StaticFilePath;
    if (!$path) {
        $path = $ctx->{mt_dir};
        $path .= '/' unless $path =~ m!/$!;
        $path .= 'mt-static/';
    }
    $path .= '/' unless $path =~ m!/$!;
    return $path;
}

sub _write_tmpl {
    my $self = shift;
    my ($tmpl, $ts_id, $type, $basename) = @_;
    die "No template object passed to write_tmpl" unless $tmpl;
    
    unless ($basename) {
        print STDERR sprintf
            'No template basename for template "%s". Skipping...',
            $tmpl->name;
        return;
    }
    
    if ( $self->{'created'}{"$type/$basename"} ) {
        print STDERR sprintf
            'Template basename "%s" previously used for template "%s".'
            .' Skipping...', "$type/$basename", $tmpl->name;
        return;
    }
    
    my $fn = File::Spec->catfile( $self->{'basedir'}, 
                                  'plugins',
                                  $self->{'key'},
                                  'templates',
                                  $ts_id,
                                  $type,
                                  $basename . '.mtml' );
    $self->_debug( "\t-- Writing template text file out to $fn" );
    unless ($self->_is_dryrun()) {            
        $self->{'fmgr'}->exists(dirname($fn)) or $self->{'fmgr'}->mkpath(dirname($fn))
            or die sprintf("Could not make path %s: %s\n",
                           dirname($fn), $self->{'fmgr'}->errstr);
        
        open FILE, ">$fn" or die "Could not open $fn for writing: $!\n";
        print FILE $tmpl->text;
        close FILE;        
    }
    $self->{'created'}{"$type/$basename"} = $tmpl->name;
}

sub _find_includes {
    my $self = shift;
    my ($obj) = @_;

    my @includes;

    # Populate list of included templates
    if ( my $includes = $obj->getElementsByTagName('Include') ) {
        my %seen;
        foreach my $tag (@$includes) {
            my $include = {};
            my $mod = $tag->[1]->{'module'} || $tag->[1]->{'widget'};
            next unless $mod;
            my $type = $tag->[1]->{widget} ? 'widget' : 'custom';
            next if exists $seen{$type}{$mod};
            $seen{$type}{$mod} = 1;
            my $other = MT->model('template')->load(
                {
                    blog_id => ( $tag->[1]->{global}
                                 ? 0
                                 : [ $obj->blog_id, 0 ]
                        ),
                                 name    => $mod,
                                 type    => $type,
                }, {
                    sort      => 'blog_id',
                    direction => 'descend',
                }
                );
            if ($other) {
                push @includes, {
                    type    => $type,
                    name    => $mod,
                    id      => $other->id,
                    blog_id => $other->blog_id
                };
            }
        }
    }
    return \@includes;
}

1;
__END__
=head1 NAME

MT::Theme::Exporter - A module for exporting a blog's templates as theme.

=head1 SYNOPSIS

    my $exporter = MT::Theme::Exporter->new({
        %options,
        logger       => sub { print STDERR $_[0] },
        key          => $TS_KEY, 
        pack_version => $TS_VERSION,
        verbose      => $VERBOSE,
        dryrun       => $DRYRUN
    });

    # Shorthand convenience variable
    %blog_id = (blog_id => $BLOG_ID);

    # No use doing a dry run if we can't see what's happening
    $VERBOSE = $DRYRUN if $DRYRUN;
    
    $exporter->export({
        blog_id => $BLOG_ID,
        name    => $name,
        static  => $static,
    });

    $exporter->write();

   
=head1 DESCRIPTION

This module provides a convenient interface to the PicApp web service.
It requires that you have been given an API Key by PicApp.

=head1 USAGE

=head2 METHODS

=over 4

=item B<export(%options)>

This method will add a blog and its theme to the list of themes to export.
This method does not physically output the theme to disk - it merely builds
the data structure in memory. This allows for other programs and code to
modify the data structure prior to committing it to disk. 

B<Options:>

=over 4

=item C<foo> - foo

=back

=item B<write()>

This method will take all of the blogs that have been exported in this batch
and write them out to a directory as a plugin. This directory can then be
zipped up and moved to another install with relative ease.

This method will do nothing if the "dryrun" option has been selected.

=back

=head1 VERSION CONTROL

L<http://github.com/byrnereese/mt-tool-exportts

=head1 AUTHORS and CREDITS

Author: Byrne Reese <byrne@endevver.com>

Contributors: Jay Allen <byrne@endevver.com>

=cut
