# This module is part of debbugs, and is released
# under the terms of the GPL version 2, or any later version. See the
# file README and COPYING for more information.
#
# [Other people have contributed to this file; their copyrights should
# be listed here too.]
# Copyright 2008 by Don Armstrong <don@donarmstrong.com>.


package Debbugs::CGI::Pkgreport;

=head1 NAME

Debbugs::CGI::Pkgreport -- specific routines for the pkgreport cgi script

=head1 SYNOPSIS


=head1 DESCRIPTION


=head1 BUGS

None known.

=cut

use warnings;
use strict;
use vars qw($VERSION $DEBUG %EXPORT_TAGS @EXPORT_OK @EXPORT);
use base qw(Exporter);

use IO::Scalar;
use Params::Validate qw(validate_with :types);

use Debbugs::Config qw(:config :globals);
use Debbugs::CGI qw(:url :html :util);
use Debbugs::Common qw(:misc :util :date);
use Debbugs::Status qw(:status);
use Debbugs::Bugs qw(bug_filter);
use Debbugs::Packages qw(:mapping);

use Debbugs::Text qw(:templates);

use POSIX qw(strftime);


BEGIN{
     ($VERSION) = q$Revision: 494 $ =~ /^Revision:\s+([^\s+])/;
     $DEBUG = 0 unless defined $DEBUG;

     @EXPORT = ();
     %EXPORT_TAGS = (html => [qw(short_bug_status_html pkg_htmlizebugs),
			      qw(pkg_javascript),
			      qw(pkg_htmlselectyesno pkg_htmlselectsuite),
			      qw(buglinklist pkg_htmlselectarch)
			     ],
		     misc => [qw(generate_package_info make_order_list),
			      qw(myurl),
			      qw(get_bug_order_index determine_ordering),
			     ],
		    );
     @EXPORT_OK = (qw());
     Exporter::export_ok_tags(keys %EXPORT_TAGS);
     $EXPORT_TAGS{all} = [@EXPORT_OK];
}

=head2 generate_package_info

     generate_package_info($srcorbin,$package)

Generates the informational bits for a package and returns it

=cut

sub generate_package_info{
     my %param = validate_with(params => \@_,
			       spec  => {binary => {type => BOOLEAN,
						    default => 1,
						   },
					 package => {type => SCALAR|ARRAYREF,
						    },
					 options => {type => HASHREF,
						    },
					 bugs    => {type => ARRAYREF,
						    },
					},
			      );

     my $output_scalar = '';
     my $output = globify_scalar(\$output_scalar);

     my $package = $param{package};

     my %pkgsrc = %{getpkgsrc()};
     my $srcforpkg = $package;
     if ($param{binary} and exists $pkgsrc{$package}
	 and defined $pkgsrc{$package}) {
	  $srcforpkg = $pkgsrc{$package};
     }

     my $showpkg = html_escape($package);
     my $maintainers = getmaintainers();
     my $maint = $maintainers->{$srcforpkg};
     if (defined $maint) {
	  print {$output} '<p>';
	  print {$output} (($maint =~ /,/)? "Maintainer for $showpkg is "
			   : "Maintainers for $showpkg are ") .
				package_links(maint => $maint);
	  print {$output} ".</p>\n";
     }
     else {
	  print {$output} "<p>No maintainer for $showpkg. Please do not report new bugs against this package.</p>\n";
     }
     my @pkgs = getsrcpkgs($srcforpkg);
     @pkgs = grep( !/^\Q$package\E$/, @pkgs );
     if ( @pkgs ) {
	  @pkgs = sort @pkgs;
	  if ($param{binary}) {
	       print {$output} "<p>You may want to refer to the following packages that are part of the same source:\n";
	  }
	  else {
	       print {$output} "<p>You may want to refer to the following individual bug pages:\n";
	  }
	  #push @pkgs, $src if ( $src && !grep(/^\Q$src\E$/, @pkgs) );
	  print {$output} scalar package_links(package=>[@pkgs]);
	  print {$output} ".\n";
     }
     my @references;
     my $pseudodesc = getpseudodesc();
     if ($package and defined($pseudodesc) and exists($pseudodesc->{$package})) {
	  push @references, "to the <a href=\"http://${debbugs::gWebDomain}/pseudo-packages${debbugs::gHTMLSuffix}\">".
	       "list of other pseudo-packages</a>";
     }
     else {
	  if ($package and defined $gPackagePages) {
	       push @references, sprintf "to the <a href=\"%s\">%s package page</a>",
		    html_escape("http://${gPackagePages}/$package"), html_escape("$package");
	  }
	  if (defined $gSubscriptionDomain) {
	       my $ptslink = $param{binary} ? $srcforpkg : $package;
	       push @references, q(to the <a href="http://).html_escape("$gSubscriptionDomain/$ptslink").q(">Package Tracking System</a>);
	  }
	  # Only output this if the source listing is non-trivial.
	  if ($param{binary} and $srcforpkg) {
	       push @references,
		    "to the source package ".
			 package_links(src=>$srcforpkg,
				       options => $param{options}) .
			      "'s bug page";
	  }
     }
     if (@references) {
	  $references[$#references] = "or $references[$#references]" if @references > 1;
	  print {$output} "<p>You might like to refer ", join(", ", @references), ".</p>\n";
     }
     if (defined $param{maint} || defined $param{maintenc}) {
	  print {$output} "<p>If you find a bug not listed here, please\n";
	  printf {$output} "<a href=\"%s\">report it</a>.</p>\n",
	       html_escape("http://${debbugs::gWebDomain}/Reporting${debbugs::gHTMLSuffix}");
     }
     if (not $maint and not @{$param{bugs}}) {
	  print {$output} "<p>There is no record of the " . html_escape($package) .
	       ($param{binary} ? " package" : " source package") .
		    ", and no bugs have been filed against it.</p>";
     }
     return $output_scalar;
}


=head2 short_bug_status_html

     print short_bug_status_html(status => read_bug(bug => 5),
                                 options => \%param,
                                );

=over

=item status -- status hashref as returned by read_bug

=item options -- hashref of options to pass to package_links (defaults
to an empty hashref)

=item bug_options -- hashref of options to pass to bug_links (default
to an empty hashref)

=item snippet -- optional snippet of information about the bug to
display below


=back



=cut

sub short_bug_status_html {
     my %param = validate_with(params => \@_,
			       spec   => {status => {type => HASHREF,
						    },
					  options => {type => HASHREF,
						      default => {},
						     },
					  bug_options => {type => HASHREF,
							  default => {},
							 },
					  snippet => {type => SCALAR,
						      default => '',
						     },
					 },
			      );

     my %status = %{$param{status}};

     $status{tags_array} = [sort(split(/\s+/, $status{tags}))];
     $status{date_text} = strftime('%a, %e %b %Y %T UTC', gmtime($status{date}));
     $status{mergedwith_array} = [split(/ /,$status{mergedwith})];

     my @blockedby= split(/ /, $status{blockedby});
     $status{blockedby_array} = [];
     if (@blockedby && $status{"pending"} ne 'fixed' && ! length($status{done})) {
	  for my $b (@blockedby) {
	       my %s = %{get_bug_status($b)};
	       next if $s{"pending"} eq 'fixed' || length $s{done};
	       push @{$status{blockedby_array}},{bug_num => $b, subject => $s{subject}, status => \%s};
	  }
     }

     my @blocks= split(/ /, $status{blocks});
     $status{blocks_array} = [];
     if (@blocks && $status{"pending"} ne 'fixed' && ! length($status{done})) {
	  for my $b (@blocks) {
	       my %s = %{get_bug_status($b)};
	       next if $s{"pending"} eq 'fixed' || length $s{done};
	       push @{$status{blocks_array}}, {bug_num => $b, subject => $s{subject}, status => \%s};
	  }
     }
     my $days = bug_archiveable(bug => $status{id},
				status => \%status,
				days_until => 1,
			       );
     $status{archive_days} = $days;
     return fill_in_template(template => 'cgi/short_bug_status',
			     variables => {status => \%status,
					   isstrongseverity => \&Debbugs::Status::isstrongseverity,
					   html_escape   => \&Debbugs::CGI::html_escape,
					   looks_like_number => \&Scalar::Util::looks_like_number,
					  },
			     hole_var  => {'&package_links' => \&Debbugs::CGI::package_links,
					   '&bug_links'     => \&Debbugs::CGI::bug_links,
					   '&version_url'   => \&Debbugs::CGI::version_url,
					   '&secs_to_english' => \&Debbugs::Common::secs_to_english,
					   '&strftime'      => \&POSIX::strftime,
					   '&maybelink'     => \&Debbugs::CGI::maybelink,
					  },
			    );

     my $result = "";

     my $showseverity;
     if ($status{severity} eq 'normal') {
	  $showseverity = '';
     }
     elsif (isstrongseverity($status{severity})) {
	  $showseverity = "Severity: <em class=\"severity\">$status{severity}</em>;\n";
     }
     else {
	  $showseverity = "Severity: <em>$status{severity}</em>;\n";
     }

     $result .= package_links(package => $status{package},
			      options  => $param{options},
			     );

     my $showversions = '';
     if (@{$status{found_versions}}) {
	  my @found = @{$status{found_versions}};
	  $showversions .= join ', ', map {s{/}{ }; html_escape($_)} @found;
     }
     if (@{$status{fixed_versions}}) {
	  $showversions .= '; ' if length $showversions;
	  $showversions .= '<strong>fixed</strong>: ';
	  my @fixed = @{$status{fixed_versions}};
	  $showversions .= join ', ', map {s{/}{ }; html_escape($_)} @fixed;
     }
     $result .= ' (<a href="'.
	  version_url(package => $status{package},
		      found   => $status{found_versions},
		      fixed   => $status{fixed_versions},
		     ).qq{">$showversions</a>)} if length $showversions;
     $result .= ";\n";

     $result .= $showseverity;
     $result .= "Reported by: ".package_links(submitter=>$status{originator},
					      class => "submitter",
					     );
     $result .= ";\nOwned by: " . package_links(owner => $status{owner},
						class => "submitter",
					       )
	  if length $status{owner};
     $result .= ";\nTags: <strong>"
	  . html_escape(join(", ", sort(split(/\s+/, $status{tags}))))
	       . "</strong>"
		    if (length($status{tags}));

     $result .= (length($status{mergedwith})?";\nMerged with ":"") .
	  bug_links(bug => [split(/ /,$status{mergedwith})],
		    class => "submitter",
		   );
     $result .= (length($status{blockedby})?";\nBlocked by ":"") .
	  bug_links(bug => [split(/ /,$status{blockedby})],
		    class => "submitter",
		   );
     $result .= (length($status{blocks})?";\nBlocks ":"") .
	  bug_links(bug => [split(/ /,$status{blocks})],
		    class => "submitter",
		   );

     if (length($status{done})) {
	  $result .= "<br><strong>Done:</strong> " . html_escape($status{done});
	  my $days = bug_archiveable(bug => $status{id},
				     status => \%status,
				     days_until => 1,
				    );
	  if ($days >= 0 and defined $status{location} and $status{location} ne 'archive') {
	       $result .= ";\n<strong>Can be archived" . ( $days == 0 ? " today" : $days == 1 ? " in $days day" : " in $days days" ) . "</strong>";
	  }
	  elsif (defined $status{location} and $status{location} eq 'archived') {
	       $result .= ";\n<strong>Archived.</strong>";
	  }
     }

     unless (length($status{done})) {
	  if (length($status{forwarded})) {
	       $result .= ";\n<strong>Forwarded</strong> to "
		    . join(', ',
			   map {maybelink($_)}
			   split /\,\s+/,$status{forwarded}
			  );
	  }
	  # Check the age of the logfile
	  my ($days_last,$eng_last) = secs_to_english(time - $status{log_modified});
	  my ($days,$eng) = secs_to_english(time - $status{date});

	  if ($days >= 7) {
	       my $font = "";
	       my $efont = "";
	       $font = "em" if ($days > 30);
	       $font = "strong" if ($days > 60);
	       $efont = "</$font>" if ($font);
	       $font = "<$font>" if ($font);

	       $result .= ";\n ${font}$eng old$efont";
	  }
	  if ($days_last > 7) {
	       my $font = "";
	       my $efont = "";
	       $font = "em" if ($days_last > 30);
	       $font = "strong" if ($days_last > 60);
	       $efont = "</$font>" if ($font);
	       $font = "<$font>" if ($font);

	       $result .= ";\n ${font}Modified $eng_last ago$efont";
	  }
     }

     $result .= ".";

     return $result;
}


sub pkg_htmlizebugs {
     my %param = validate_with(params => \@_,
			       spec   => {bugs => {type => ARRAYREF,
						  },
					  names => {type => ARRAYREF,
						   },
					  title => {type => ARRAYREF,
						   },
					  prior => {type => ARRAYREF,
						   },
					  order => {type => ARRAYREF,
						   },
					  ordering => {type => SCALAR,
						      },
					  bugusertags => {type => HASHREF,
							  default => {},
							 },
					  bug_rev => {type => BOOLEAN,
						      default => 0,
						     },
					  bug_order => {type => SCALAR,
						       },
					  repeatmerged => {type => BOOLEAN,
							   default => 1,
							  },
					  include => {type => ARRAYREF,
						      default => [],
						     },
					  exclude => {type => ARRAYREF,
						      default => [],
						     },
					  this     => {type => SCALAR,
						       default => '',
						      },
					  options  => {type => HASHREF,
						       default => {},
						      },
					  dist     => {type => SCALAR,
						       optional => 1,
						      },
					 }
			      );
     my @bugs = @{$param{bugs}};

     my @status = ();
     my %count;
     my $header = '';
     my $footer = "<h2 class=\"outstanding\">Summary</h2>\n";

     my @dummy = ($gRemoveAge); #, @gSeverityList, @gSeverityDisplay);  #, $gHTMLExpireNote);

     if (@bugs == 0) {
	  return "<HR><H2>No reports found!</H2></HR>\n";
     }

     if ( $param{bug_rev} ) {
	  @bugs = sort {$b<=>$a} @bugs;
     }
     else {
	  @bugs = sort {$a<=>$b} @bugs;
     }
     my %seenmerged;

     my %common = (
		   'show_list_header' => 1,
		   'show_list_footer' => 1,
		  );

     my %section = ();
     # Make the include/exclude map
     my %include;
     my %exclude;
     for my $include (make_list($param{include})) {
	  next unless defined $include;
	  my ($key,$value) = split /\s*:\s*/,$include,2;
	  unless (defined $value) {
	       $key = 'tags';
	       $value = $include;
	  }
	  push @{$include{$key}}, split /\s*,\s*/, $value;
     }
     for my $exclude (make_list($param{exclude})) {
	  next unless defined $exclude;
	  my ($key,$value) = split /\s*:\s*/,$exclude,2;
	  unless (defined $value) {
	       $key = 'tags';
	       $value = $exclude;
	  }
	  push @{$exclude{$key}}, split /\s*,\s*/, $value;
     }

     foreach my $bug (@bugs) {
	  my %status = %{get_bug_status(bug=>$bug,
					(exists $param{dist}?(dist => $param{dist}):()),
					bugusertags => $param{bugusertags},
					(exists $param{version}?(version => $param{version}):()),
					(exists $param{arch}?(arch => $param{arch}):(arch => $config{default_architectures})),
				       )};
	  next unless %status;
	  next if bug_filter(bug => $bug,
			     status => \%status,
			     repeat_merged => $param{repeatmerged},
			     seen_merged => \%seenmerged,
			     (keys %include ? (include => \%include):()),
			     (keys %exclude ? (exclude => \%exclude):()),
			    );

	  my $html = "<li>"; #<a href=\"%s\">#%d: %s</a>\n<br>",
	       #bug_url($bug), $bug, html_escape($status{subject});
	  $html .= short_bug_status_html(status  => \%status,
					 options => $param{options},
					) . "\n";
	  push @status, [ $bug, \%status, $html ];
     }
     if ($param{bug_order} eq 'age') {
	  # MWHAHAHAHA
	  @status = sort {$a->[1]{log_modified} <=> $b->[1]{log_modified}} @status;
     }
     elsif ($param{bug_order} eq 'agerev') {
	  @status = sort {$b->[1]{log_modified} <=> $a->[1]{log_modified}} @status;
     }
     for my $entry (@status) {
	  my $key = "";
	  for my $i (0..$#{$param{prior}}) {
	       my $v = get_bug_order_index($param{prior}[$i], $entry->[1]);
	       $count{"g_${i}_${v}"}++;
	       $key .= "_$v";
	  }
	  $section{$key} .= $entry->[2];
	  $count{"_$key"}++;
     }

     my $result = "";
     if ($param{ordering} eq "raw") {
	  $result .= "<UL class=\"bugs\">\n" . join("", map( { $_->[ 2 ] } @status ) ) . "</UL>\n";
     }
     else {
	  $header .= "<div class=\"msgreceived\">\n<ul>\n";
	  my @keys_in_order = ("");
	  for my $o (@{$param{order}}) {
	       push @keys_in_order, "X";
	       while ((my $k = shift @keys_in_order) ne "X") {
		    for my $k2 (@{$o}) {
			 $k2+=0;
			 push @keys_in_order, "${k}_${k2}";
		    }
	       }
	  }
	  for my $order (@keys_in_order) {
	       next unless defined $section{$order};
	       my @ttl = split /_/, $order;
	       shift @ttl;
	       my $title = $param{title}[0]->[$ttl[0]] . " bugs";
	       if ($#ttl > 0) {
		    $title .= " -- ";
		    $title .= join("; ", grep {($_ || "") ne ""}
				   map { $param{title}[$_]->[$ttl[$_]] } 1..$#ttl);
	       }
	       $title = html_escape($title);

	       my $count = $count{"_$order"};
	       my $bugs = $count == 1 ? "bug" : "bugs";

	       $header .= "<li><a href=\"#$order\">$title</a> ($count $bugs)</li>\n";
	       if ($common{show_list_header}) {
		    my $count = $count{"_$order"};
		    my $bugs = $count == 1 ? "bug" : "bugs";
		    $result .= "<H2 CLASS=\"outstanding\"><a name=\"$order\"></a>$title ($count $bugs)</H2>\n";
	       }
	       else {
		    $result .= "<H2 CLASS=\"outstanding\">$title</H2>\n";
	       }
	       $result .= "<div class=\"msgreceived\">\n<UL class=\"bugs\">\n";
	       $result .= "\n\n\n\n";
	       $result .= $section{$order};
	       $result .= "\n\n\n\n";
	       $result .= "</UL>\n</div>\n";
	  } 
	  $header .= "</ul></div>\n";

	  $footer .= "<div class=\"msgreceived\">\n<ul>\n";
	  for my $i (0..$#{$param{prior}}) {
	       my $local_result = '';
	       foreach my $key ( @{$param{order}[$i]} ) {
		    my $count = $count{"g_${i}_$key"};
		    next if !$count or !$param{title}[$i]->[$key];
		    $local_result .= "<li>$count $param{title}[$i]->[$key]</li>\n";
	       }
	       if ( $local_result ) {
		    $footer .= "<li>$param{names}[$i]<ul>\n$local_result</ul></li>\n";
	       }
	  }
	  $footer .= "</ul>\n</div>\n";
     }

     $result = $header . $result if ( $common{show_list_header} );
     $result .= $footer if ( $common{show_list_footer} );
     return $result;
}

sub pkg_javascript {
     return fill_in_template(template=>'cgi/pkgreport_javascript',
			    );
}

sub pkg_htmlselectyesno {
     my ($name, $n, $y, $default) = @_;
     return sprintf('<select name="%s"><option value=no%s>%s</option><option value=yes%s>%s</option></select>', $name, ($default ? "" : " selected"), $n, ($default ? " selected" : ""), $y);
}

sub pkg_htmlselectsuite {
     my $id = sprintf "b_%d_%d_%d", $_[0], $_[1], $_[2];
     my @suites = ("stable", "testing", "unstable", "experimental");
     my %suiteaka = ("stable", "etch", "testing", "lenny", "unstable", "sid");
     my $defaultsuite = "unstable";

     my $result = sprintf '<select name=dist id="%s">', $id;
     for my $s (@suites) {
	  $result .= sprintf '<option value="%s"%s>%s%s</option>',
	       $s, ($defaultsuite eq $s ? " selected" : ""),
		    $s, (defined $suiteaka{$s} ? " (" . $suiteaka{$s} . ")" : "");
     }
     $result .= '</select>';
     return $result;
}

sub pkg_htmlselectarch {
     my $id = sprintf "b_%d_%d_%d", $_[0], $_[1], $_[2];
     my @arches = qw(alpha amd64 arm hppa i386 ia64 m68k mips mipsel powerpc s390 sparc);

     my $result = sprintf '<select name=arch id="%s">', $id;
     $result .= '<option value="any">any architecture</option>';
     for my $a (@arches) {
	  $result .= sprintf '<option value="%s">%s</option>', $a, $a;
     }
     $result .= '</select>';
     return $result;
}

sub myurl {
     my %param = @_;
     return html_escape(pkg_url(map {exists $param{$_}?($_,$param{$_}):()}
				qw(archive repeatmerged mindays maxdays),
				qw(version dist arch package src tag maint submitter)
			       )
		       );
}

sub make_order_list {
     my $vfull = shift;
     my @x = ();

     if ($vfull =~ m/^([^:]+):(.*)$/) {
	  my $v = $1;
	  for my $vv (split /,/, $2) {
	       push @x, "$v=$vv";
	  }
     }
     else {
	  for my $v (split /,/, $vfull) {
	       next unless $v =~ m/.=./;
	       push @x, $v;
	  }
     }
     push @x, "";		# catch all
     return @x;
}

sub get_bug_order_index {
     my $order = shift;
     my $status = shift;
     my $pos = -1;

     my %tags = ();
     %tags = map { $_, 1 } split / /, $status->{"tags"}
	  if defined $status->{"tags"};

     for my $el (@${order}) {
	  $pos++;
	  my $match = 1;
	  for my $item (split /[+]/, $el) {
	       my ($f, $v) = split /=/, $item, 2;
	       next unless (defined $f and defined $v);
	       my $isokay = 0;
	       $isokay = 1 if (defined $status->{$f} and $v eq $status->{$f});
	       $isokay = 1 if ($f eq "tag" && defined $tags{$v});
	       unless ($isokay) {
		    $match = 0;
		    last;
	       }
	  }
	  if ($match) {
	       return $pos;
	       last;
	  }
     }
     return $pos + 1;
}

sub buglinklist {
     my ($prefix, $infix, @els) = @_;
     return '' if not @els;
     return $prefix . bug_linklist($infix,'submitter',@els);
}


# sets: my @names; my @prior; my @title; my @order;

sub determine_ordering {
     my %param = validate_with(params => \@_,
			      spec => {cats => {type => HASHREF,
					       },
				       param => {type => HASHREF,
						},
				       ordering => {type => SCALARREF,
						   },
				       names    => {type => ARRAYREF,
						   },
				       pend_rev => {type => BOOLEAN,
						    default => 0,
						   },
				       sev_rev  => {type => BOOLEAN,
						    default => 0,
						   },
				       prior    => {type => ARRAYREF,
						   },
				       title    => {type => ARRAYREF,
						   },
				       order    => {type => ARRAYREF,
						   },
				      },
			     );
     $param{cats}{status}[0]{ord} = [ reverse @{$param{cats}{status}[0]{ord}} ]
	  if ($param{pend_rev});
     $param{cats}{severity}[0]{ord} = [ reverse @{$param{cats}{severity}[0]{ord}} ]
	  if ($param{sev_rev});

     my $i;
     if (defined $param{param}{"pri0"}) {
	  my @c = ();
	  $i = 0;
	  while (defined $param{param}{"pri$i"}) {
	       my $h = {};

	       my ($pri) = make_list($param{param}{"pri$i"});
	       if ($pri =~ m/^([^:]*):(.*)$/) {
		    $h->{"nam"} = $1; # overridden later if necesary
		    $h->{"pri"} = [ map { "$1=$_" } (split /,/, $2) ];
	       }
	       else {
		    $h->{"pri"} = [ split /,/, $pri ];
	       }

	       ($h->{"nam"}) = make_list($param{param}{"nam$i"})
		    if (defined $param{param}{"nam$i"});
	       $h->{"ord"} = [ map {split /\s*,\s*/} make_list($param{param}{"ord$i"}) ]
		    if (defined $param{param}{"ord$i"});
	       $h->{"ttl"} = [ map {split /\s*,\s*/} make_list($param{param}{"ttl$i"}) ]
		    if (defined $param{param}{"ttl$i"});

	       push @c, $h;
	       $i++;
	  }
	  $param{cats}{"_"} = [@c];
	  ${$param{ordering}} = "_";
     }

     ${$param{ordering}} = "normal" unless defined $param{cats}{${$param{ordering}}};

     sub get_ordering {
	  my @res;
	  my $cats = shift;
	  my $o = shift;
	  for my $c (@{$cats->{$o}}) {
	       if (ref($c) eq "HASH") {
		    push @res, $c;
	       }
	       else {
		    push @res, get_ordering($cats, $c);
	       }
	  }
	  return @res;
     }
     my @cats = get_ordering($param{cats}, ${$param{ordering}});

     sub toenglish {
	  my $expr = shift;
	  $expr =~ s/[+]/ and /g;
	  $expr =~ s/[a-z]+=//g;
	  return $expr;
     }
 
     $i = 0;
     for my $c (@cats) {
	  $i++;
	  push @{$param{prior}}, $c->{"pri"};
	  push @{$param{names}}, ($c->{"nam"} || "Bug attribute #" . $i);
	  if (defined $c->{"ord"}) {
	       push @{$param{order}}, $c->{"ord"};
	  }
	  else {
	       push @{$param{order}}, [ 0..$#{$param{prior}[-1]} ];
	  }
	  my @t = @{ $c->{"ttl"} } if defined $c->{ttl};
	  if (@t < $#{$param{prior}[-1]}) {
	       push @t, map { toenglish($param{prior}[-1][$_]) } @t..($#{$param{prior}[-1]});
	  }
	  push @t, $c->{"def"} || "";
	  push @{$param{title}}, [@t];
     }
}




1;


__END__





