
package Debbugs::Bugs;

=head1 NAME

Debbugs::Bugs -- Bug selection routines for debbugs

=head1 SYNOPSIS

use Debbugs::Bugs qw(get_bugs);


=head1 DESCRIPTION

This module is a replacement for all of the various methods of
selecting different types of bugs.

It implements a single function, get_bugs, which defines the master
interface for selecting bugs.

It attempts to use subsidiary functions to actually do the selection,
in the order specified in the configuration files. [Unless you're
insane, they should be in order from fastest (and often most
incomplete) to slowest (and most complete).]

=head1 BUGS

=head1 FUNCTIONS

=cut

use warnings;
use strict;
use vars qw($VERSION $DEBUG %EXPORT_TAGS @EXPORT_OK @EXPORT);
use base qw(Exporter);

BEGIN{
     $VERSION = 1.00;
     $DEBUG = 0 unless defined $DEBUG;

     @EXPORT = ();
     %EXPORT_TAGS = ();
     @EXPORT_OK = (qw(get_bugs));
     $EXPORT_TAGS{all} = [@EXPORT_OK];
}

use Debbugs::Config qw(:config);
use Params::Validate qw(validate_with :types);
use IO::File;
use Debbugs::Status qw(splitpackages);
use Debbugs::Packages qw(getsrcpkgs);
use Debbugs::Common qw(getparsedaddrs getmaintainers getmaintainers_reverse);
use Fcntl qw(O_RDONLY);
use MLDBM qw(DB_File Storable);

=head2 get_bugs

     get_bugs()

=head3 Parameters

The following parameters can either be a single scalar or a reference
to an array. The parameters are ANDed together, and the elements of
arrayrefs are a parameter are ORed. Future versions of this may allow
for limited regular expressions, and/or more complex expressions.

=over

=item package -- name of the binary package

=item src -- name of the source package

=item maint -- address of the maintainer

=item submitter -- address of the submitter

=item severity -- severity of the bug

=item status -- status of the bug

=item tag -- bug tags

=item owner -- owner of the bug

=item dist -- distribution (I don't know about this one yet)

=item bugs -- list of bugs to search within

=item function -- see description below

=back

=head3 Special options

The following options are special options used to modulate how the
searches are performed.

=over

=item archive -- whether to search archived bugs or normal bugs;
defaults to false.

=item usertags -- set of usertags and the bugs they are applied to

=back


=head3 Subsidiary routines

All subsidiary routines get passed exactly the same set of options as
get_bugs. If for some reason they are unable to handle the options
passed (for example, they don't have the right type of index for the
type of selection) they should die as early as possible. [Using
Params::Validate and/or die when files don't exist makes this fairly
trivial.]

This function will then immediately move on to the next subroutine,
giving it the same arguments.

=head3 function

This option allows you to provide an arbitrary function which will be
given the information in the index.db file. This will be super, super
slow, so only do this if there's no other way to write the search.

You'll be given a list (which you can turn into a hash) like the
following:

 (pkg => ['a','b'], # may be a scalar (most common)
  bug => 1234,
  status => 'pending',
  submitter => 'boo@baz.com',
  severity => 'serious',
  tags => ['a','b','c'], # may be an empty arrayref
 )

The function should return 1 if the bug should be included; 0 if the
bug should not.

=cut

sub get_bugs{
     my %param = validate_with(params => \@_,
			       spec   => {package   => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  src       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  maint     => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  submitter => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  severity  => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  status    => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  tag       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  owner     => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  dist      => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  function  => {type => CODEREF,
							optional => 1,
						       },
					  bugs      => {type => SCALAR|ARRAYREF,
							optional => 1,
						       },
					  archive   => {type => BOOLEAN,
							default => 0,
						       },
					  usertags  => {type => HASHREF,
							optional => 1,
						       },
					 },
			      );

     # Normalize options
     my %options = %param;
     my @bugs;
     # A configuration option will set an array that we'll use here instead.
     for my $routine (qw(Debbugs::Bugs::get_bugs_by_idx Debbugs::Bugs::get_bugs_flatfile)) {
	  my ($package) = $routine =~ m/^(.+)\:\:/;
	  eval "use $package;";
	  if ($@) {
	       # We output errors here because using an invalid function
	       # in the configuration file isn't something that should
	       # be done.
	       warn "use $package failed with $@";
	       next;
	  }
	  @bugs = eval "${routine}(\%options)";
	  if ($@) {

	       # We don't output errors here, because failure here
	       # via die may be a perfectly normal thing.
	       print STDERR "$@" if $DEBUG;
	       next;
	  }
	  last;
     }
     # If no one succeeded, die
     if ($@) {
	  die "$@";
     }
     return @bugs;
}

=head2 get_bugs_by_idx

This routine uses the by-$index.idx indicies to try to speed up
searches.


=cut

sub get_bugs_by_idx{
     my %param = validate_with(params => \@_,
			       spec   => {package   => {type => SCALAR|ARRAYREF,
							optional => 1,
						       },
					  submitter => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  severity  => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  tag       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  archive   => {type => BOOLEAN,
							default => 0,
						       },
					  src       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  maint     => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					 },
			      );
     my %bugs = ();

     # We handle src packages, maint and maintenc by mapping to the
     # appropriate binary packages, then removing all packages which
     # don't match all queries
     my @packages = __handle_pkg_src_and_maint(map {exists $param{$_}?($_,$param{$_}):()}
					       qw(package src maint)
					      );
     if (exists $param{package} or
	 exists $param{src} or
	 exists $param{maint}) {
	  delete @param{qw(maint src)};
	  $param{package} = [@packages];
     }
     my $keys = keys(%param) - 1;
     die "Need at least 1 key to search by" unless $keys;
     my $arc = $param{archive} ? '-arc':'';
     my %idx;
     for my $key (grep {$_ ne 'archive'} keys %param) {
	  my $index = $key;
	  $index = 'submitter-email' if $key eq 'submitter';
	  $index = "$config{spool_dir}/by-${index}${arc}.idx";
	  tie(%idx, MLDBM => $index, O_RDONLY)
	       or die "Unable to open $index: $!";
	  for my $search (__make_list($param{$key})) {
	       next unless defined $idx{$search};
	       for my $bug (keys %{$idx{$search}}) {
		    # increment the number of searches that this bug matched
		    $bugs{$bug}++;
	       }
	  }
	  untie %idx or die 'Unable to untie %idx';
     }
     # Throw out results that do not match all of the search specifications
     return map {$keys <= $bugs{$_}?($_):()} keys %bugs;
}


=head2 get_bugs_flatfile

This is the fallback search routine. It should be able to complete all
searches. [Or at least, that's the idea.]

=cut

sub get_bugs_flatfile{
     my %param = validate_with(params => \@_,
			       spec   => {package   => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  src       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  maint     => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  submitter => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  severity  => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  status    => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  tag       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
# not yet supported
# 					  owner     => {type => SCALAR|ARRAYREF,
# 						        optional => 1,
# 						       },
# 					  dist      => {type => SCALAR|ARRAYREF,
# 						        optional => 1,
# 						       },
					  archive   => {type => BOOLEAN,
							default => 1,
						       },
					  usertags  => {type => HASHREF,
							optional => 1,
						       },
					  function  => {type => CODEREF,
							optional => 1,
						       },
					 },
			      );
     my $flatfile;
     if ($param{archive}) {
	  $flatfile = new IO::File "$debbugs::gSpoolDir/index.archive", 'r'
	       or die "Unable to open $debbugs::gSpoolDir/index.archive for reading: $!";
     }
     else {
	  $flatfile = new IO::File "$debbugs::gSpoolDir/index.db", 'r'
	       or die "Unable to open $debbugs::gSpoolDir/index.db for reading: $!";
     }
     my %usertag_bugs;
     if (exists $param{tag} and exists $param{usertags}) {

	  # This complex slice makes a hash with the bugs which have the
          # usertags passed in $param{tag} set.
	  @usertag_bugs{map {@{$_}}
			     @{$param{usertags}}{__make_list($param{tag})}
			} = (1) x @{$param{usertags}}{__make_list($param{tag})}
     }
     # We handle src packages, maint and maintenc by mapping to the
     # appropriate binary packages, then removing all packages which
     # don't match all queries
     my @packages = __handle_pkg_src_and_maint(map {exists $param{$_}?($_,$param{$_}):()}
					       qw(package src maint)
					      );
     if (exists $param{package} or
	 exists $param{src} or
	 exists $param{maint}) {
	  delete @param{qw(maint src)};
	  $param{package} = [@packages];
     }
     my @bugs;
     while (<$flatfile>) {
	  next unless m/^(\S+)\s+(\d+)\s+(\d+)\s+(\S+)\s+\[\s*([^]]*)\s*\]\s+(\w+)\s+(.*)$/;
	  my ($pkg,$bug,$status,$submitter,$severity,$tags) = ($1,$2,$3,$4,$5,$6,$7);
	  next if exists $param{bug} and not grep {$bug == $_} __make_list($param{bugs});
	  if (exists $param{pkg}) {
	       my @packages = splitpackages($pkg);
	       next unless grep { my $pkg_list = $_;
				  grep {$pkg_list eq $_} __make_list($param{pkg})
			     } @packages;
	  }
	  if (exists $param{src}) {
	       my @src_packages = map { getsrcpkgs($_)} __make_list($param{src});
	       my @packages = splitpackages($pkg);
	       next unless grep { my $pkg_list = $_;
				  grep {$pkg_list eq $_} @packages
			     } @src_packages;
	  }
	  if (exists $param{submitter}) {
	       my @p_addrs = map {$_->address}
		    map {lc(getparsedaddrs($_))}
			 __make_list($param{submitter});
	       my @f_addrs = map {$_->address}
		    getparsedaddrs($submitter||'');
	       next unless grep { my $f_addr = $_; 
				  grep {$f_addr eq $_} @p_addrs
			     } @f_addrs;
	  }
	  next if exists $param{severity} and not grep {$severity eq $_} __make_list($param{severity});
	  next if exists $param{status} and not grep {$status eq $_} __make_list($param{status});
	  if (exists $param{tag}) {
	       my $bug_ok = 0;
	       # either a normal tag, or a usertag must be set
	       $bug_ok = 1 if exists $param{usertags} and $usertag_bugs{$bug};
	       my @bug_tags = split ' ', $tags;
	       $bug_ok = 1 if grep {my $bug_tag = $_;
				    grep {$bug_tag eq $_} __make_list($param{tag});
			       } @bug_tags;
	       next unless $bug_ok;
	  }
	  # We do this last, because a function may be slow...
	  if (exists $param{function}) {
	       my @bug_tags = split ' ', $tags;
	       my @packages = splitpackages($pkg);
	       my $package = (@packages > 1)?\@packages:$packages[0];
	       next unless
		    $param{function}->(pkg       => $package,
				       bug       => $bug,
				       status    => $status,
				       submitter => $submitter,
				       severity  => $severity,
				       tags      => \@bug_tags,
				      );
	  }
	  push @bugs, $bug;
     }
     return @bugs;
}

sub __handle_pkg_src_and_maint{
     my %param = validate_with(params => \@_,
			       spec   => {package   => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  src       => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					  maint     => {type => SCALAR|ARRAYREF,
						        optional => 1,
						       },
					 },
			       allow_extra => 1,
			      );

     my @packages = __make_list($param{package});
     my $package_keys = @packages?1:0;
     my %packages;
     @packages{@packages} = (1) x @packages;
     if (exists $param{src}) {
	  # We only want to increment the number of keys if there is
	  # something to match
	  my $key_inc = 0;
	  for my $package (map { getsrcpkgs($_)} __make_list($param{src})) {
	       $packages{$package}++;
	       $key_inc=1;
	  }
	  $package_keys += $key_inc;
     }
     if (exists $param{maint}) {
	  my $key_inc = 0;
	  my $maint_rev = getmaintainers_reverse();
	  for my $package (map { exists $maint_rev->{$_}?@{$maint_rev->{$_}}:()}
			   __make_list($param{maint})) {
	       $packages{$package}++;
	       $key_inc = 1;
	  }
	  $package_keys += $key_inc;
     }
     return grep {$packages{$_} >= $package_keys} keys %packages;
}


# This private subroutine takes a scalar and turns it into a list;
# transforming arrayrefs into their contents along the way. It also
# turns undef into the empty list.
sub __make_list{
     return map {defined $_?(ref($_) eq 'ARRAY'?@{$_}:$_):()} @_;
}

1;

__END__