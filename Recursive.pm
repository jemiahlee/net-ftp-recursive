package Net::FTP::Recursive;

use Net::FTP;
use Cwd 'getcwd';
use strict;

use vars qw/@ISA $VERSION $file_type $dir_type $link_type/;
use vars qw/%options %filesSeen %dirsSeen %linkMap $success/;

@ISA = qw|Net::FTP|;
$VERSION = '1.10';

###################################################################
# Constants for the different file types
###################################################################
$file_type = 1;
$dir_type = 2;
$link_type = 3;

sub new {
  my $class = shift;

  my $ftp = new Net::FTP(@_);

  bless $ftp, $class if defined($ftp);

  return $ftp;
}

#------------------------------------------------------------------
# - cd to directory, lcd to directory
# - grab all files, process symlinks according to options
#
# - foreach directory
#    - create it unless options say to flatten
#    - call function recursively.
#    - cd .. unless options say to flatten
#    - lcd ..
#
# -----------------------------------------------------------------

sub rget{

  my($ftp) = shift;

  %options = (ParseSub => \&parse_files,
	      SymLinkIgnore => 1,
	      @_,
	      InitialDir => $ftp->pwd
	     );    #setup the options

  %dirsSeen = ();
  %filesSeen = ();

  if ( $options{SymlinkFollow} ) {
    $dirsSeen{ $ftp->pwd } = Cwd::cwd();
  }

  local $success = '';

  $ftp->_rget(); #do the real work here

  undef %filesSeen;
  undef %dirsSeen;

  return $success;

}

sub _rget {

  my($ftp) = shift;

  my @dirs;

  my(@files) = $options{ParseSub}->($ftp->dir);

  @files = grep { ref eq 'Net::FTP::Recursive::File' } @files;

  @files = grep { $_->filename =~ $options{MatchAll} } @files if $options{MatchAll};

  @files = grep { $_->filename !~ $options{OmitAll} } @files if $options{OmitAll};

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;


  my $remote_pwd = $ftp->pwd;
  my $local_pwd = Cwd::cwd();

 FILE:
  foreach my $file (@files){
    #used to make sure that if we're deleting the files, we
    #successfully retrieved the file
    my $get_success = 1;
    my $filename = $file->filename();

    #if it's not a directory we just need to get the file.
    if ( $file->isPlainFile() ) {

      next FILE if $options{MatchFiles}
	           and $filename !~ $options{MatchFiles};

      next FILE if $options{OmitFiles}
	           and $filename =~ $options{OmitFiles};

      if ( $options{FlattenTree} and $filesSeen{$filename} ) {
	print STDERR "Retrieving $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	$get_success = $ftp->get( $filename, "$filename.$filesSeen{$filename}" );
      } else {
	print STDERR "Retrieving $filename.\n" if $ftp->debug;
	$get_success = $ftp->get( $filename );
      }

      $filesSeen{$filename}++ if $options{FlattenTree};

      if ( $options{RemoveRemoteFiles} ) {
	if ( $options{CheckSizes} ) {
	  if ( -e $filename and ( (-s $filename) == $file->size ) ) {
	    $ftp->delete( $filename );
	    print STDERR "Deleting '$filename'.\n" if $ftp->debug;
	  } else {
	    print STDERR "Will not delete '$filename': remote file size and local file size do not match!\n" if $ftp->debug;
	  }
	} else {
	  if ( $get_success ) {
	    $ftp->delete( $filename );
	    print STDERR "Deleting '$filename'.\n" if $ftp->debug;
	  } else {
	    print STDERR "Will not delete '$filename': error retrieving file!\n" if $ftp->debug;
	  }
	}
      }
    }

    #if it's a directory, we have more work to do.
    elsif ( $file->isDirectory() ) {

      next FILE if $options{MatchDirs}
	           and $filename !~ $options{MatchDirs};

      next FILE if $options{OmitDirs}
	           and $filename =~ $options{OmitDirs};

      if ( $options{SymlinkFollow} ) {

	$dirsSeen{qq<$remote_pwd/$filename>} = qq<$local_pwd/$filename>;
	print STDERR qq<Mapping '$remote_pwd/$filename' to '$local_pwd/$filename'.\n>;

      }

	push @dirs, $file;

    } #end of elsif( $file->isDirectory() )

    elsif ( $file->isSymlink() ) {

      #SymlinkIgnore is really the default.
      if ( $options{SymlinkIgnore} ) {
	print STDERR "Ignoring the symlink ", $file->filename(), ".\n" if $ftp->debug;
	if ( $options{RemoveRemoteFiles} ) {
	  $ftp->delete( $file->filename );
	  print STDERR 'Deleting \'', $file->filename,
	    "'.\n" if $ftp->debug;
	}
	next FILE; #skip the stuff further in the if block

      }

      next FILE if $options{MatchLinks}
	           and $filename !~ $options{MatchLinks};

      next FILE if $options{OmitLinks}
	           and $filename =~ $options{OmitLinks};

      #otherwise we need to see if it points to a directory
      print STDERR "Testing to see if $filename refers to a directory.\n" if $ftp->debug;
      my $path_before_chdir = $ftp->pwd;
      my $is_directory = 0;

      if ( $ftp->cwd($file->filename()) ) {
	$ftp->cwd( $path_before_chdir );
	$is_directory = 1;
      }

      if ( not $is_directory and $options{SymlinkCopy} ) { #if it's not and
	                                                   #SymlinkCopy is set,
                                                           #we'll copy the file

	#symlink to non-directory.  need to grab it and
	#make sure the filename does not collide
	my $get_success;
	if ( $options{FlattenTree} and $filesSeen{$filename}) {
	  print STDERR "Retrieving $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	  $get_success = $ftp->get( $filename, "$filename.$filesSeen{$filename}" );
	} else {
	  print STDERR "Retrieving $filename.\n" if $ftp->debug;
	  $get_success = $ftp->get( $filename );
	}

	$filesSeen{$filename}++;

	if ( $get_success and $options{RemoveRemoteFiles} ) {
	  $ftp->delete( $filename );
	  print STDERR "Deleting '$filename'.\n" if $ftp->debug;
	}
      } #end of if (not $is_directory and $options{SymlinkCopy}

      elsif ( $is_directory and $options{SymlinkFollow} ) {

	#we need to resolve the link to an absolute path

	my $remote_abs_path = path_resolve( $file->linkName,
					    $remote_pwd,
					    $filename );

	print STDERR qq<'$filename' got converted to '$remote_abs_path'.\n>;

	#if it's a directory structure we've already seen,
	#we'll just make a relative symlink to that
	#directory

	# OR

	#if it's in the same tree that we started
	#downloading, we should get to it later, so we'll
	#just make a relative symlink to that directory.

	if ( $dirsSeen{$remote_abs_path}
	     or $remote_abs_path =~ s%^$options{InitialDir}
				     %$dirsSeen{$options{InitialDir}}%x ){

	  unless( $options{FlattenTree} ){
	    print STDERR qq<\$dirsSeen{$remote_abs_path} = $dirsSeen{$remote_abs_path}.\n>;
	    print STDERR qq<Calling convert_to_relative( '$local_pwd/$filename', '>, ($dirsSeen{$remote_abs_path} || $remote_abs_path), qq<');\n>;
	    my $rel_path = convert_to_relative( qq<$local_pwd/$filename>,
						$dirsSeen{$remote_abs_path} || $remote_abs_path
					      );
	    print STDERR qq<Symlinking '$filename' to '$rel_path'.\n> if $ftp->debug;
	    symlink $rel_path, $filename;
	  }

	  if ( $options{RemoveRemoteFiles} ) {
	    $ftp->delete( $filename );
	    print STDERR "Deleting '$filename'.\n" if $ftp->debug;
	  }

	  next FILE;
	}

	# Otherwise we need to grab the directory and put
	# the info in a hash in case there is another link
	# to this directory
	else {

	  print STDERR "New directory to grab!\n";
	  push @dirs, $file;

	  $dirsSeen{$remote_abs_path} = qq<$local_pwd/$filename>;
	  print STDERR qq<Mapping '$remote_abs_path' to '$local_pwd/$filename'.\n>;
	  #no deletion, will handle that down below.

	}

      } #end of elsif($is_directory and $options{SymlinkFollow})

      # if it's a dir and SymlinkFollow is not set but
      # SymlinkLink is set, we'll just create the link.

      # OR

      # if it was a file and SymlinkCopy is not set but
      # SymlinkLink is, we'll just create the link.

      elsif ( $options{SymlinkLink} ) {
	#we need to make the symlink and that's it.
	symlink $file->linkName(), $file->filename();
	if ( $options{RemoveRemoteFiles} ) {
	  $ftp->delete( $file->filename );
	  print STDERR 'Deleting \'', $file->filename,
	    "'.\n" if $ftp->debug;
	}
	next FILE;
      } #end of elsif( $options{SymlinkLink} ){

    }

    $success .= qq<Had a problem retrieving '$remote_pwd/$filename'!\n> unless $get_success;

  } #end of foreach ( @files )

  undef @files; #save memory, maybe, in recursing.

  #this will do depth-first retrieval

  foreach my $file (@dirs) {

    my $filename = $file->filename;

    #check to make sure that we actually have permissions to
    #change into the directory

    unless ( $ftp->cwd($filename) ) {
      print STDERR 'Was unable to cd to ', $filename,
	", skipping!\n" if $ftp->debug;
      $success .= qq<Was not able to chdir to '$remote_pwd/$filename'!\n>;
      next;
    }

    unless ( $options{FlattenTree} ) {
      print STDERR "Making dir: " . $filename . "\n" if $ftp->debug;

      mkdir $filename, "0755"; #mkdir, ignore errors due to
                               #pre-existence

      chmod 0755, $filename;   # just in case the UMASK in the
                               # mkdir doesn't work

      unless ( chdir $filename ){
	print STDERR 'Could not change to the local directory ',
	  $filename, "!\n" if $ftp->debug;
	$ftp->cwd( $remote_pwd );
	$success .= <Was not able to chdir to local directory '$local_pwd/$filename'!\n>;
	next;
      }
    }

    #don't delete files that are accessed through a symlink

    my $remove;
    if ( $options{RemoveRemoteFiles} and $file->isSymlink() ) {
      $remove = $options{RemoveRemoteFiles};
      $options{RemoveRemoteFiles} = 0;
    }

    #need to recurse
    print STDERR 'Calling rget in ', $remote_pwd, "\n" if $ftp->debug;
    $ftp->_rget( );

    #once we've recursed, we'll go back up a dir.
    print STDERR "Returned from rget in " . $remote_pwd . ".\n" if $ftp->debug;

    if ( $file->isSymlink() ) {
      $ftp->cwd( $remote_pwd );
      $options{RemoveRemoteFiles} = $remove;
    } else {
      $ftp->cdup;
    }

    chdir ".." unless $options{FlattenTree};

    if ( $options{RemoveRemoteFiles} ) {
      if ( $file->isSymlink() ) {
	print STDERR 'Removing symlink \'', $filename,
	  "'.\n" if $ftp->debug;
	$ftp->delete( $filename );
      } else {
	print STDERR 'Removing directory\'', $filename,
	  "'.\n" if $ftp->debug;
	$ftp->rmdir( $filename );
      }
    }
  }

}

sub rput{

  my($ftp) = shift;

  %options = (DirCommand => 'ls -la',
	      ParseSub => \&parse_files,
	      @_
	     );    #setup the options

  %filesSeen = ();

  local $success = '';

  $ftp->_rput(); #do the real work here

  undef %filesSeen;

  return $success;
}

#------------------------------------------------------------------
# - make the directory on the remote host
# - cd to directory, lcd to directory
# - foreach directory, call the function recursively
# - cd .., lcd ..
# -----------------------------------------------------------------

sub _rput {

  my($ftp) = @_;

  my(@ls, @dirs);

  @ls = qx[$options{DirCommand}];

  chomp(@ls);

  my @files = $options{ParseSub}->(@ls);

  @files = grep { ref eq 'Net::FTP::Recursive::File' } @files;

  print STDERR join("\n", map { $_->originalLine() } @files),"\n" if $ftp->debug;

  my $remote_pwd = $ftp->pwd;

  foreach my $file (@files){
    my $put_success = 1;
    my $filename = $file->filename(); #we're gonna need it a lot here
    #if it's a file we just need to put the file

    if ( $file->isPlainFile() ) {

      #we're going to check for filename conflicts here if
      #the user has opted to flatten out the tree
      if ( $options{FlattenTree} and $filesSeen{$filename} ) {
	print STDERR "Sending $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	$put_success = $ftp->put( $filename, "$filename.$filesSeen{$filename}");
      } else {
	print STDERR "Sending $filename.\n" if $ftp->debug;
	$put_success = $ftp->put( $filename );
      }

      $filesSeen{$filename}++ if $options{FlattenTree};

      if ( $options{RemoveLocalFiles} ) {
	print STDERR 'Removing \'', $file->filename(),
	  "' from the local system.\n" if $ftp->debug;
	unlink $file->filename();
      }

    }

    #otherwise, if it's a directory, we have to create the directory
    #on the remote machine, cd to it, then recurse

    elsif ( $file->isDirectory() ) {
      push @dirs, $file;
    }

    #if it's a symlink, there's nothing we can do with it.

    elsif ( $file->isSymlink() ) {

      if ( $options{SymlinkIgnore} ) {
	print STDERR "Not doing anything to ", $file->filename(), " as it is a link.\n" if $ftp->debug;
	if ( $options{RemoveLocalFiles} ) {
	  print STDERR 'Removing \'', $file->filename(),
	    "' from the local system.\n" if $ftp->debug;
	  unlink $file->filename();
	}
      } else {

	if ( -f $file->filename() and $options{SymlinkCopy} ) {
	  if ( $options{FlattenTree} and $filesSeen{$filename}) {
	    print STDERR "Sending $filename as $filename.$filesSeen{$filename}.\n" if $ftp->debug;
	    $put_success = $ftp->put( $filename, "$filename.$filesSeen{$filename}" );
	  } else {
	    print STDERR "Sending $filename.\n" if $ftp->debug;
	    $put_success = $ftp->put( $filename );
	  }
	  $filesSeen{$filename}++;

	  if ( $put_success and $options{RemoveLocalFiles} ) {
	    print STDERR 'Removing \'', $file->filename(),
	      "' from the local system.\n" if $ftp->debug;
	    unlink $file->filename();
	  }

	} elsif ( -d $file->filename() and $options{SymlinkFollow} ) {
	  #then it's a directory, we need to add it to the
	  #list of directories to grab
	  push @dirs, $file;

	}
      }
    }

    $success .= qq<Had trouble putting $filename into $remote_pwd\n> unless $put_success;

  }

  undef @files; #save memory, maybe, in recursing.

  #we might use this in the loop if we follow a symlink
  #unfortunately, perl doesn't seem to keep track of
  #symlinks very well, so we'll use an absolute path to
  #chdir at the end.
  my $local_pwd  = Cwd::cwd();

  foreach my $file (@dirs) {

    my $filename = $file->filename();

    unless ( $options{FlattenTree} ) {

      print STDERR "Making dir: ", $filename, "\n" if $ftp->debug;
      unless( $ftp->mkdir($filename) ){
	print STDERR 'Could not make remote directory ',
	  $filename, "!\n" if $ftp->debug;
	$success .= qq<Could not make remote directory '$remote_pwd/$filename'!\n>;
      }

      unless ( $ftp->cwd($filename) ){
	print STDERR 'Could not change remote directory to ',
	  $filename, ", skipping!\n" if $ftp->debug;
	$success .= qq<Could not change remote directory to '$remote_pwd/$filename'!\n>;
	next;
      }
    }

    unless ( chdir $filename ){
      print STDERR 'Could not change to the local directory ',
	$filename, "!\n" if $ftp->debug;
      $ftp->cdup;
      $success .= qq<Could not change to the local directory '$local_pwd/$filename'!\n>;
      next;
    }

    print STDERR "Calling rput in ", $remote_pwd, "\n" if $ftp->debug;
    $ftp->_rput( );

    #once we've recursed, we'll go back up a dir.
    print STDERR 'Returned from rput in ',
      $filename, ".\n" if $ftp->debug;

    $ftp->cdup unless $options{FlattenTree};

    if ( $file->isSymlink() ) {
      chdir $local_pwd;
      unlink $filename if $options{RemoveLocalFiles};
    } else {
      chdir '..';
      rmdir $filename if $options{RemoveLocalFiles};
    }

  }

}


sub rdir{

  my($ftp) = shift;

  %options = (ParseSub => \&parse_files,
	      OutputFormat => '%p %lc %u %g %s %d %f %l',
	      @_,
	      InitialDir => $ftp->pwd
	     );    #setup the options

  return unless $options{Filehandle};

  %dirsSeen = ();
  %filesSeen = ();

  $dirsSeen{$ftp->pwd}++;

  local $success = '';

  $ftp->_rdir;

  undef %dirsSeen;   #just make sure to cleanup for the next
  undef %filesSeen;  #time

  return $success;

}

sub _rdir{

  my($ftp) = shift;

  my(@ls) = $ftp->dir;

  my(@files) = $options{ParseSub}->( @ls );

  @files = grep { ref eq 'Net::FTP::Recursive::File' } @files;

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;

  my(@dirs);
  my $fh = $options{Filehandle};
  print $fh $ftp->pwd, ":\n" unless $options{FilenameOnly};

  my $remote_pwd = $ftp->pwd;
  my $local_pwd = Cwd::cwd();

 FILE:
  foreach my $file (@files) {

    my $filename = $file->filename;

    if ( $file->isSymlink() ) {

      if ( $ftp->cwd($filename) ) {
	$ftp->cwd( $remote_pwd );


	#we need to resolve the link to an absolute path

	my $remote_abs_path = path_resolve( $file->linkName,
					  $remote_pwd,
					  $filename );

	print STDERR qq<'$filename' got converted to '$remote_abs_path'.\n>;

	#if it's a directory structure we've already seen,
	#we'll just treat it as a regular file

	# OR

	#if it's in the same tree that we started
	#downloading, we should get to it later, so we'll
	#just treat it as a regular file

	unless ( $dirsSeen{$remote_abs_path}
		 or $remote_abs_path =~ m%^$options{InitialDir}% ){

	  # Otherwise we need to grab the directory and put
	  # the info in a hash in case there is another link
	  # to this directory
	  push @dirs, $file;
	  $dirsSeen{$remote_abs_path}++;
	  print STDERR qq<Mapping '$remote_abs_path' to '$dirsSeen{$remote_abs_path}'.\n>;

	}
      } #end of if( $ftp->cwd( $filename ) ){
    } #end of if( $file->isSymlink() ){
    elsif ( $file->isDirectory() ) {
        push @dirs, $file;
	next FILE if $options{FilenameOnly};
    }

    if( $options{FilenameOnly} ){
      print $fh $remote_pwd, '/', $filename,"\n";
    } else {
      print $fh $file->originalLine(), "\n";
    }

  }

  undef @files; #mark this for cleanup, it might matter
                #(save memory) since we're recursing

  print $fh "\n" unless $options{FilenameOnly};

  foreach my $dir (@dirs){

    my $dirname = $dir->filename;

    unless ( $ftp->cwd( $dirname ) ){
      print STDERR 'Was unable to cd to ', $dirname,
                   " in $remote_pwd, skipping!\n" if $ftp->debug;
      $success .= qq<Was unable to cd to '$remote_pwd/$dirname'\n>;
      next;
    }

    print STDERR "Calling rdir in ", $remote_pwd, "\n" if $ftp->debug;
    $ftp->_rdir( );

    #once we've recursed, we'll go back up a dir.
    print STDERR "Returned from rdir in " . $dirname . ".\n" if $ftp->debug;

    if ( $dir->isSymlink() ) {
      $ftp->cwd($remote_pwd);
    } else {
      $ftp->cdup;
    }
  }

}

sub rls{
  my $ftp = shift;
  return $ftp->rdir(@_, FilenameOnly => 1);
}

#---------------------------------------------------------------
# CD to directory
# Recurse through all subdirectories and delete everything
# This will not go into symlinks
#---------------------------------------------------------------

sub rdelete {

   my($ftp) = shift;

   %options = (ParseSub => \&parse_files,
               @_
              );    #setup the options

   local $success = '';

   $ftp->_rdelete(); #do the real work here

   return $success;

}

sub _rdelete {

  my $ftp = shift;

  my @dirs;

  my(@files) = $options{ParseSub}->($ftp->dir);

  @files = grep { ref eq 'Net::FTP::Recursive::File' } @files;

  print STDERR join("\n",map { $_->originalLine() } @files),"\n" if $ftp->debug;

  my $remote_pwd = $ftp->pwd;

  foreach my $file (@files){

    #just delete plain files and symlinks
    if ( $file->isPlainFile() or $file->isSymlink() ) {
      my $filename = $file->filename();
      my $del_success = $ftp->delete($filename);
      $success .= qq<Had a problem deleting '$remote_pwd/$filename'!\n> unless $del_success;

    }

    #otherwise, if it's a directory, we have more work to do.
    elsif ( $file->isDirectory() ) {
      push @dirs, $file;
    }

  }

  undef @files; #save memory, maybe, when recursing.

  #this will do depth-first delete
  foreach my $file (@dirs) {

    my $filename = $file->filename();

    #in case we didn't have permissions to cd into that
    #directory
    unless ( $ftp->cwd( $file->filename() ) ){
      print STDERR qq<Could not change dir to $filename!\n> if $ftp->debug;
      $success .= qq<Could not change dir to '$remote_pwd/$filename'!\n>;
      next;
    }

    #need to recurse
    print STDERR 'Calling _rdelete in ', $ftp->pwd, "\n" if $ftp->debug;
    $ftp->_rdelete( );

    #once we've recursed, we'll go back up a dir.
    print STDERR "Returned from _rdelete in " . $ftp->pwd . ".\n" if
      $ftp->debug;
    $ftp->cdup;

    ##now delete the directory we just came out of
    $ftp->rmdir($file->filename()) 
      or $success .= qq<Could not delete remote directory '$remote_pwd/$filename'!\n>;
  }

}

#-------------------------------------------------------------------#
# Should look at all of the output from the current dir and parse
# through and extract the filename, date, size, and whether it is a
# directory or not
#
# The date should also have a time, so that if the script needs to be
# run several times in one day, it will grab any files that changed
# that day.
#-------------------------------------------------------------------#

sub parse_files {

  #throw away the first line, it should be a "total" line
  #  shift unless $options{KeepFirstLine};
  # this should be unnecessary with the change I made below.

  my(@to_return) = ();

  foreach my $line (@_) {

    my($file); #reinitialize var

    next unless my @fields =
      $line =~ /^
                 (\S+)\s+ #permissions %p
                 (\d+)\s+ #link count %lc
                 (\w+)\s+ #user owner %u
                 (\w+)\s+ #group owner %g
                 (\d+)\s+ #size %s
                 (\w+\s+\w+\s+\S+)\s+ #last modification date %d
                 (.+?)\s* #filename %f
                 (?:->\s*(.+))? #optional link part %l
                $
               /x;

    my($perms) = ($1);

    next if $fields[6] =~ /^\.{1,2}$/;

    if ($perms =~/^-/){
      $file = Net::FTP::Recursive::File->new(IsPlainFile => 1,
					    IsDirectory => 0,
					    IsSymlink   => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~ /^d/) {
      $file = Net::FTP::Recursive::File->new(IsDirectory => 1,
					    IsPlainFile => 0,
					    IsSymlink   => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } elsif ($perms =~/^l/) {
      $file = Net::FTP::Recursive::File->new(IsSymlink => 1,
					    IsDirectory => 0,
					    IsPlainFile => 0,
					    OriginalLine => $line,
					    Fields => [@fields]);
    } else {
      next; #didn't match, skip the file
    }

    push(@to_return, $file);

  }

  return(@to_return);

}

=begin blah

  This subroutine takes a path and converts the '.' and
  '..' parts of it to make it into a proper absolute path.

=end blah

=cut

sub path_resolve{
  my($link_path, $pwd, $filename) = @_;
  my $remote_pwd; #value to return

  #this case is so that if we have gotten to this
  #symlink through another symlink, we can actually
  #retrieve the correct files (make the correct
  #symlink, whichever)

  if ( $linkMap{$pwd} and $link_path !~ m#^/# ) {
    $remote_pwd = $linkMap{$pwd} . '/' . $link_path;
  }

  # if it was an absolute path, just make sure there aren't
  # any . or .. in it, and make sure it ends with a /
  elsif ( $link_path =~ m#^/# ) {
    $remote_pwd = $link_path;
  }

  #otherwise, it was a relative path and we need to
  #prepend the current working directory onto it and
  #then eliminate any .. or . that are present
  else {
    $remote_pwd = $pwd;
    $remote_pwd =~ s#(?<!/)$#/#;
    $remote_pwd .= $link_path;
  }

  #Collapse the resulting path if it has . or .. in it.  The
  #while loop is needed to make it start over after each
  #match (as it will need to go back for parts of the
  #regex).  It's probably possible to write a regex to do it
  #without the while loop, but I don't think that making it
  #less readable is a good idea.  :)

  while ( $remote_pwd =~ s#(?:^|/)\.(?:/|$)#/# ) {}
  while ( $remote_pwd =~ s#(?:/[^/]+)?/\.\.(?:/|$)#/# ){}

  #the %linkMap will store as keys the absolute paths
  #to the links and the values will be the "real"
  #absolute paths to those locations (to take care of
  #../-type links

  $filename =~ s#/$##;
  $remote_pwd =~ s#/$##;

  $pwd =~ s#(?<!/)$#/#; #make sure there's a / on the end
  $linkMap{$pwd . $filename} = $remote_pwd;

  $remote_pwd; #return the result

}

=begin blah

  This subroutine takes two absolute paths and basically
  'links' them together.  The idea is that all of the paths
  that are created for the symlinks should be relative
  paths.  This is the sub that does that.

  There are essentially 6 cases:

    -Different root hierarchy:
        /tmp/testdata/blah -> /usr/local/bin/blah
    -Current directory:
        /tmp/testdata/blah -> /tmp/testdata
    -A file in the current directory:
        /tmp/testdata/blah -> /tmp/testdata/otherblah
    -Lower in same hierarchy:
        /tmp/testdata/blah -> /tmp/testdata/dir/otherblah
    -A higher directory along the same path (part of link abs path) :
        /tmp/testdata/dir/dir2/otherblah -> /tmp/testdata/dir
    -In same hierarchy, somewhere else:
        /tmp/testdata/dir/dir2/otherblah -> /tmp/testdata/dir/file

  The last two cases are very similar, the only difference
  will be that it will create '../' for the first rather
  than the possible '../../dir'.  The last case will indeed
  get the '../file'.

=end blah

=cut

sub convert_to_relative{
  my($link_loc, $realfile) = (shift, shift);
  my $i;
  my $result;
  my($new_realfile, $new_link, @realfile_parts, @link_parts);

  @realfile_parts = split m#/#, $realfile;
  @link_parts = split m#/#, $link_loc;

  for ( $i = 0; $i < @realfile_parts; $i++ ) {
    last unless $realfile_parts[$i] eq $link_parts[$i];
  }

  $new_realfile = join '/', @realfile_parts[$i..$#realfile_parts];
  $new_link = join '/', @link_parts[$i..$#link_parts];

  if( $i == 1 ){
    $result = $realfile;
  } elsif ( $i > $#realfile_parts and $i == $#link_parts  ) {
    $result = '.';
  } elsif ( $i == $#realfile_parts and $i == $#link_parts ) {
    $result = $realfile_parts[$i];
  } elsif ( $i >= $#link_parts  ) {
    $result = join '/', @realfile_parts[$i..$#realfile_parts];
  } else {
    $result = '../' x ($#link_parts - $i);
    $result .= join '/', @realfile_parts[$i..$#realfile_parts]
      if $#link_parts - $i > 0;
  }

  return $result;

}


package Net::FTP::Recursive::File;

use vars qw/@ISA/;

@ISA = ();

sub new{

  my $pkg = shift;

  my $self = bless {@_}, $pkg;

}

sub originalLine{
  return $_[0]->{OriginalLine};
}

sub filename{
  return $_[0]->{Fields}[6];
}

sub size{
  return $_[0]->{Fields}[4];
}

sub linkName{
  return $_[0]->{Fields}[7];
}

sub isSymlink{
  return $_[0]->{IsSymlink};
}

sub isDirectory{
  return $_[0]->{IsDirectory};
}

sub isPlainFile{
  return $_[0]->{IsPlainFile};
}

sub fields{
  return $_[0]->{Fields};
}

1;

__END__

=head1 NAME

Net::FTP::Recursive - Recursive FTP Client class

=head1 SYNOPSIS

    use Net::FTP::Recursive;

    $ftp = Net::FTP::Recursive->new("some.host.name", Debug => 0);
    $ftp->login("anonymous",'me@here.there');
    $ftp->cwd('/pub');
    $ftp->rget( ParseSub => \&yoursub );
    $ftp->quit;

=head1 DESCRIPTION

C<Net::FTP::Recursive> is a class built on top of the Net::FTP package
that implements recursive get and put methods for the retrieval and
sending of entire directory structures.

This module's default behavior is such that the remote ftp
server should understand the "dir" command and return
UNIX-style directory listings.  If you'd like to provide
your own function for parsing the data retrieved from this
command (in case the ftp server does not understand the
"dir" command), all you need do is provide a function to one
of the Recursive method calls.  This function will take the
output from the "dir" command (as a list of lines) and
should return a list of Net::FTP::Recursive::File objects.
This module is described below.

All of the methods also take an optional C<KeepFirstLine>
argument which is passed on to the default parsing routine.
This argument supresses the discarding of the first line of
output from the dir command.  wuftpd servers provide a
total line, the default behavior is to throw that total line
away.  If yours does not provide the total line,
C<KeepFirstLine> is for you.  This argument is used like the
others, you provide the argument as the key in a key value
pair where the value is true (ie, KeepFirstLine => 1).

When the C<Debug> flag is used with the C<Net::FTP> object, the
C<Recursive> package will print some messages to C<STDERR>.

All of the methods should return false ('') if they are
successful, and a true value if unsuccessful.  The true
value will be a string of the concatenations of all of the
error messages (with newlines).  Note that this might be the
opposite of the more intuitive return code.

=head1 CONSTRUCTOR

=over

=item new (HOST [,OPTIONS])

A call to the new method to create a new
C<Net::FTP::Recursive> object just calls the C<Net::FTP> new
method.  Please refer to the C<Net::FTP> documentation for
more information.

=back

=head1 METHODS

=over


=item rget ( [ParseSub =>\&yoursub] [,FlattenTree => 1]
             [,RemoveRemoteFiles => 1] )

The recursive get method call.  This will recursively
retrieve the ftp object's current working directory and its
contents into the local current working directory.

This will also take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rget call (ie, $ftp->rget(SymlinkIgnore => 1)):

=over 12

=item SymlinkIgnore - disregards symlinks (default)

=item SymlinkCopy - copies the link target from the server to the client (if accessible).  Works on files other than a directory.  For directories, see the C<SymlinkFollow> option.

=item SymlinkFollow - will recurse into a symlink if it
points to a directory.  This option may be given along with
one of the others above.

=item SymlinkLink - creates the link on the client.  This is
superceded by each of the previous options.

=back

The C<SymlinkFollow> option, as of v1.6, does more
sophisticated handling of symlinks.  It will detect and
avoid cycles, on all client platforms.  Also, if on a UNIX
(tm) platform, if it detects a cycle, it will create a
symlink to the location where it downloaded the directory
(or will download it subsequently, if it is in the subtree
under where the recursing started).  On Windows, it will
call symlink just as on UNIX (tm), but that's probably not
gonna do much for you.  :)

The C<FlattenTree> optional argument will retrieve all of
the files from the remote directory structure and place them
in the current local directory.  This option will resolve
filename conflicts by retrieving files with the same name
and renaming them in a "$filename.$i" fashion, where $i is
the number of times it has retrieved a file with that name.

The optional C<RemoveRemoteFiles> argument to the function
will allow the client to delete files from the server after
it retrieves them.  The default behavior is to leave all
files and directories intact.  The default behavior for this
is to check the return code from the FTP GET call.  If that
is successful, it will delete the file.  C<CheckSizes> is an
additional argument that will check the filesize of the
local file against the file size of the remote file, and
only if they are the same will it delete the file.  You must
l provide the C<RemoveRemoteFiles> option in order for
option to affect the behavior of the code.  This check will
only be performed for regular files, not directories or
symlinks.  This is a new option as of v1.10, and it is 
currently only implemented for rget, not rput.

For the v1.6 release, I have also added some additional
functionality that will allow the client to be more specific
in choosing those files that are retrieved.  All of these
options take a regex object (made using the C<qr> operator)
as their value.  You may choose to use one or more of these
options, they are applied in the order that they are
listed.  They are:

=over

=item MatchAll - Will process file that matches this regex,
regardless of whether it is a plainish file, directory, or a
symlink.  This behavior can be overridden with the previous
options.

=item OmitAll - Do not process file that matches this
regex. Also may be overridden with the previous options.

=item MatchFiles - Only transfer plainish (not a directory
or a symlink) files that match this pattern.

=item OmitFiles - Omit those plainish files that match this
pattern.

=item MatchDirs - Only recurse into directories that match
this pattern.

=item OmitDirs - Do not recurse into directories that match
this pattern.

=item MatchLinks - Only deal with those links that match
this pattern (based on your symlink option, above).

=item OmitLinks - Do not deal with links that match this
pattern.

=back

Currently, the added functionality given to the rget method
is not implemented for the rput method.

=item rput ( [ParseSub => \&yoursub] [,DirCommand => $cmd]
             [,FlattenTree => 1] [,RemoveLocalFiles => 1])

The recursive put method call.  This will recursively send the local
current working directory and its contents to the ftp object's current
working directory.

This method will take an optional set of arguments to tell
it what the local directory listing command will be.  By
default, this is "ls -al".  If you change the behavior
through this argument, you probably also need to provide a
ParseSub, as described above.

This will take an optional argument that will control what
happens when a symbolic link is encountered on the ftp
server.  The default is to ignore the symlink, but you can
control the behavior by passing one of these arguments to
the rput call (ie, $ftp->rput(SymlinkIgnore => 1)):

=over

=item SymlinkIgnore - disregards symlinks

=item SymlinkCopy - will copy the link target from the client to the server.

=item SymLinkFollow - will recurse into a symlink if it
points to a directory.  This does not do cycle checking, use
with EXTREME caution.  This option may be given along with one of
the others above.

=back

The C<FlattenTree> optional argument will send all of the
files from the local directory structure and place them in
the current remote directory.  This option will resolve
filename conflicts by sending files with the same name
and renaming them in a "$filename.$i" fashion, where $i is
the number of times it has retrieved a file with that name.

The optional C<RemoveLocalFiles> argument to the function
will allow the client to delete files from the client after
it sends them.  The default behavior is to leave all files
and directories intact.  This option will only attempt to
delete files that were actually transferred, symlinks
(unless you set SymlinkCopy and it is a plain file) will not
be removed (and of course any non-empty directories).

=item rdir ( Filehandle => $fh [, FilenameOnly => 1]
             [, ParseSub => \&yoursub ] )

The recursive dir method call.  This will recursively retrieve
directory contents from the server in a breadth-first fashion.

The method needs to be passed a filehandle to print to.  The method
call just does a C<print $fh>, so as long as this call can succeed
with whatever you pass to this function, it'll work.

The second, optional argument, is to retrieve only the filenames
(including path information).  The default is to display all of the
information returned from the $ftp-dir call.

This method WILL follow symlinks.  It has the same basic
cycle-checking code that is in rget, so it should not infinitely
loop.

=item rls ( Filehandle => $fh [, ParseSub => \&yoursub] )

The recursive ls method call.  This will recursively
retrieve directory contents from the server in a
breadth-first fashion.  This is equivalent to calling
C<$ftp->rdir( Filehandle => $fh, FilenameOnly => 1 )>.

=item rdelete ( [ ParseSub => \&yoursub ] )

The recursive delete method call.  This will recursively
delete everything in the directory structure.  This
disregards the C<SymlinkFollow> option and does not recurse
into symlinks that refer to directories.


=head1 Net::FTP::Recursive::File

This is a helper class that encapsulates the data
representing one file in a directory listing.

=head1 METHODS

=over

=item new ( )

This method creates the File object.  It should be passed
several parameters.  It should always be passed:

=over

=item OriginalLine => $line

=item Fields => \@fields

=back

And it should also be passed at least one (but only one a
true value) of:

=over

=item IsPlainFile => 1

=item IsDirectory => 1

=item IsSymlink => 1

=back

OriginalLine should provide the original line from the
output of a directory listing.

Fields should provide an 8 element list that supplies
information about the file.  The fields, in order, should
be:

=over

=item Permissions

=item Link Count

=item User Owner

=item Group Owner

=item Size

=item Last Modification Date/Time

=item Filename

=item Link Target

=back

The C<IsPlainFile>, C<IsDirectory>, and C<IsSymlink> fields
need to be supplied so that for the output on your
particular system, your code (in the ParseSub) can determine
which type of file it is so that the Recursive calls can
take the appropriate action for that file.  Only one of
these three fields should be set to a "true" value.

=back

=head1 TODO LIST

=over

=item Allow for formats to be given for output on rdir/rls.

=back

=head1 REPORTING BUGS

When reporting bugs, please provide as much information as possible.
A script that exhibits the bug would also be helpful, as well as
output with the "Debug => 1" flag turned on in the FTP object.

=head1 AUTHOR

Jeremiah Lee <texasjdl_AT_yahoo.com>

=head1 SEE ALSO

L<Net::FTP>

L<Net::Cmd>

ftp(1), ftpd(8), RFC 959

=head1 CREDITS

(in Chronological order, sorry if I missed anyone)

Andrew Winkler - for various input into the module.
Raj Mudaliar - documentation fix.
Brian Reischl - for rdelete code.
Chris Smith - for RemoveRemoteFiles code.
Zainul Charbiwala - bug report & code to fix.
Brian McGraw - bug report & feature request.
Isaac Koenig - bug report

=head1 COPYRIGHT

Copyright (c) 2001-2003 Jeremiah Lee.

This program is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

