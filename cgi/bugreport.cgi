#!/usr/bin/perl -wT

package debbugs;

use strict;
use POSIX qw(strftime tzset);
use MIME::Parser;
use MIME::Decoder;
use IO::Scalar;
use IO::File;

#require '/usr/lib/debbugs/errorlib';
require './common.pl';

require '/etc/debbugs/config';
require '/etc/debbugs/text';

use vars(qw($gEmailDomain $gHTMLTail $gSpoolDir $gWebDomain));

# for read_log_records
use Debbugs::Log;
use Debbugs::MIME qw(convert_to_utf8 decode_rfc1522);

use Scalar::Util qw(looks_like_number);

my %param = readparse();

my $tail_html;

my $ref = $param{'bug'} || quitcgi("No bug number");
$ref =~ /(\d+)/ or quitcgi("Invalid bug number");
$ref = $1;
my $short = "#$ref";
my $msg = $param{'msg'} || "";
my $att = $param{'att'};
my $boring = ($param{'boring'} || 'no') eq 'yes'; 
my $terse = ($param{'terse'} || 'no') eq 'yes';
my $reverse = ($param{'reverse'} || 'no') eq 'yes';
my $mbox = ($param{'mbox'} || 'no') eq 'yes'; 
my $mime = ($param{'mime'} || 'yes') eq 'yes';

my $trim_headers = ($param{trim} || ($msg?'no':'yes')) eq 'yes';

# Not used by this script directly, but fetch these so that pkgurl() and
# friends can propagate them correctly.
my $archive = ($param{'archive'} || 'no') eq 'yes';
my $repeatmerged = ($param{'repeatmerged'} || 'yes') eq 'yes';
set_option('archive', $archive);
set_option('repeatmerged', $repeatmerged);

my $buglog = buglog($ref);

if (defined $ENV{REQUEST_METHOD} and $ENV{REQUEST_METHOD} eq 'HEAD' and not defined($att) and not $mbox) {
    print "Content-Type: text/html; charset=utf-8\n";
    my @stat = stat $buglog;
    if (@stat) {
	my $mtime = strftime '%a, %d %b %Y %T GMT', gmtime($stat[9]);
	print "Last-Modified: $mtime\n";
    }
    print "\n";
    exit 0;
}

sub display_entity ($$$$\$\@);
sub display_entity ($$$$\$\@) {
    my $entity = shift;
    my $ref = shift;
    my $top = shift;
    my $xmessage = shift;
    my $this = shift;
    my $attachments = shift;

    my $head = $entity->head;
    my $disposition = $head->mime_attr('content-disposition');
    $disposition = 'inline' if not defined $disposition or $disposition eq '';
    my $type = $entity->effective_type;
    my $filename = $entity->head->recommended_filename;
    $filename = '' unless defined $filename;
    $filename = decode_rfc1522($filename);

    if ($top and not $terse) {
	 my $header = $entity->head;
	 $$this .= "<pre class=\"headers\">\n";
	 if ($trim_headers) {
	      my @headers;
	      foreach (qw(From To Cc Subject Date)) {
		   my $head_field = $head->get($_);
		   next unless defined $head_field and $head_field ne '';
		   push @headers, qq(<b>$_:</b> ) . htmlsanit(decode_rfc1522($head_field));
	      }
	      $$this .= join(qq(), @headers) unless $terse;
	 } else {
	      $$this .= htmlsanit(decode_rfc1522($entity->head->stringify));
	 }
	 $$this .= "</pre>\n";
    }

    unless (($top and $type =~ m[^text(?:/plain)?(?:;|$)]) or
	    ($type =~ m[^multipart/])) {
	push @$attachments, $entity;
	my @dlargs = ($ref, "msg=$xmessage", "att=$#$attachments");
	push @dlargs, "filename=$filename" if $filename ne '';
	my $printname = $filename;
	$printname = 'Message part ' . ($#$attachments + 1) if $filename eq '';
	$$this .= '<pre class="mime">[<a href="' . bugurl(@dlargs) . qq{">$printname</a> } .
		  "($type, $disposition)]</pre>\n";

	if ($msg and defined($att) and $att eq $#$attachments) {
	    my $head = $entity->head;
	    chomp(my $type = $entity->effective_type);
	    my $body = $entity->stringify_body;
	    print "Content-Type: $type";
	    my ($charset) = $head->get('Content-Type:') =~ m/charset\s*=\s*\"?([\w-]+)\"?/i;
	    print qq(; charset="$charset") if defined $charset;
	    print "\n";
	    if ($filename ne '') {
		my $qf = $filename;
		$qf =~ s/"/\\"/g;
		$qf =~ s[.*/][];
		print qq{Content-Disposition: inline; filename="$qf"\n};
	    }
	    print "\n";
	    my $decoder = new MIME::Decoder($head->mime_encoding);
	    $decoder->decode(new IO::Scalar(\$body), \*STDOUT);
	    exit(0);
	}
    }

    return if not $top and $disposition eq 'attachment' and not defined($att);
    return unless ($type =~ m[^text/?] and
		   $type !~ m[^text/(?:html|enriched)(?:;|$)]) or
		  $type =~ m[^application/pgp(?:;|$)] or
		  $entity->parts;

    if ($entity->is_multipart) {
	my @parts = $entity->parts;
	foreach my $part (@parts) {
	    display_entity($part, $ref, 0, $xmessage,
			   $$this, @$attachments);
	    $$this .= "\n";
	}
    } elsif ($entity->parts) {
	# We must be dealing with a nested message.
	$$this .= "<blockquote>\n";
	my @parts = $entity->parts;
	foreach my $part (@parts) {
	    display_entity($part, $ref, 1, $xmessage,
			   $$this, @$attachments);
	    $$this .= "\n";
	}
	$$this .= "</blockquote>\n";
    } else {
	 if (not $terse) {
	      my $content_type = $entity->head->get('Content-Type:') || "text/html";
	      my ($charset) = $content_type =~ m/charset\s*=\s*\"?([\w-]+)\"?/i;
	      my $body = $entity->bodyhandle->as_string;
	      $body = convert_to_utf8($body,$charset) if defined $charset;
	      $body = htmlsanit($body);
	      # Add links to URLs
	      $body =~ s,((ftp|http|https)://[\S~-]+?/?)((\&gt\;)?[)]?[']?[:.\,]?(\s|$)),<a href=\"$1\">$1</a>$3,go;
	      # Add links to bug closures
	      $body =~ s[(closes:\s*(?:bug)?\#?\s?\d+(?:,?\s*(?:bug)?\#?\s?\d+)*)
			][my $temp = $1; $temp =~ s{(\d+)}{qq(<a href=").bugurl($1).qq(">$1</a>)}ge; $temp;]gxie;
	      $$this .= qq(<pre class="message">$body</pre>\n);
	 }
    }
}

my %maintainer = %{getmaintainers()};
my %pkgsrc = %{getpkgsrc()};

my $indexentry;
my $showseverity;

my $tpack;
my $tmain;

$ENV{"TZ"} = 'UTC';
tzset();

my $dtime = strftime "%a, %e %b %Y %T UTC", localtime;
$tail_html = $debbugs::gHTMLTail;
$tail_html =~ s/SUBSTITUTE_DTIME/$dtime/;

my %status = %{getbugstatus($ref)};
unless (%status) {
    print <<EOF;
Content-Type: text/html; charset=utf-8

<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head><title>$short - $debbugs::gProject $debbugs::gBug report logs</title></head>
<body>
<h1>$debbugs::gProject $debbugs::gBug report logs - $short</h1>
<p>There is no record of $debbugs::gBug $short.
Try the <a href="http://$gWebDomain/">search page</a> instead.</p>
$tail_html</body></html>
EOF
    exit 0;
}

$|=1;

$tpack = lc $status{'package'};
my @tpacks = splitpackages($tpack);

if  ($status{severity} eq 'normal') {
	$showseverity = '';
} elsif (isstrongseverity($status{severity})) {
	$showseverity = "Severity: <em class=\"severity\">$status{severity}</em>;\n";
} else {
	$showseverity = "Severity: $status{severity};\n";
}

$indexentry .= "<div class=\"msgreceived\">\n";
$indexentry .= htmlpackagelinks($status{package}, 0) . ";\n";

foreach my $pkg (@tpacks) {
    my $tmaint = defined($maintainer{$pkg}) ? $maintainer{$pkg} : '(unknown)';
    my $tsrc = defined($pkgsrc{$pkg}) ? $pkgsrc{$pkg} : '(unknown)';

    $indexentry .=
            htmlmaintlinks(sub { $_[0] == 1 ? "Maintainer for $pkg is\n"
                                            : "Maintainers for $pkg are\n" },
                           $tmaint);
    $indexentry .= ";\nSource for $pkg is\n".
            '<a href="'.srcurl($tsrc)."\">$tsrc</a>" if ($tsrc ne "(unknown)");
    $indexentry .= ".\n";
}

$indexentry .= "<br>";
$indexentry .= htmladdresslinks("Reported by: ", \&submitterurl,
                                $status{originator}) . ";\n";
$indexentry .= sprintf "Date: %s.\n",
		(strftime "%a, %e %b %Y %T UTC", localtime($status{date}));

$indexentry .= "<br>Owned by: " . htmlsanit($status{owner}) . ".\n"
              if length $status{owner};

$indexentry .= "</div>\n";

my @descstates;

$indexentry .= "<h3>$showseverity";
$indexentry .= sprintf "Tags: %s;\n", 
		htmlsanit(join(", ", sort(split(/\s+/, $status{tags}))))
			if length($status{tags});
$indexentry .= "<br>" if (length($showseverity) or length($status{tags}));

my @merged= split(/ /,$status{mergedwith});
if (@merged) {
	my $descmerged = 'Merged with ';
	my $mseparator = '';
	for my $m (@merged) {
		$descmerged .= $mseparator."<a href=\"" . bugurl($m) . "\">#$m</a>";
		$mseparator= ",\n";
	}
	push @descstates, $descmerged;
}

if (@{$status{found_versions}}) {
    my $foundtext = 'Found in ';
    $foundtext .= (@{$status{found_versions}} == 1) ? 'version ' : 'versions ';
    $foundtext .= join ', ', map htmlsanit($_), @{$status{found_versions}};
    push @descstates, $foundtext;
}

if (@{$status{fixed_versions}}) {
    my $fixedtext = '<strong>Fixed</strong> in ';
    $fixedtext .= (@{$status{fixed_versions}} == 1) ? 'version ' : 'versions ';
    $fixedtext .= join ', ', map htmlsanit($_), @{$status{fixed_versions}};
    if (length($status{done})) {
	$fixedtext .= ' by ' . htmlsanit(decode_rfc1522($status{done}));
    }
    push @descstates, $fixedtext;
} elsif (length($status{done})) {
    push @descstates, "<strong>Done:</strong> ".htmlsanit(decode_rfc1522($status{done}));
} elsif (length($status{forwarded})) {
    push @descstates, "<strong>Forwarded</strong> to ".maybelink($status{forwarded});
}


my @blockedby= split(/ /, $status{blockedby});
if (@blockedby && $status{"pending"} ne 'fixed' && ! length($status{done})) {
    for my $b (@blockedby) {
        my %s = %{getbugstatus($b)};
        next if $s{"pending"} eq 'fixed' || length $s{done};
        push @descstates, "Fix blocked by <a href=\"" . bugurl($b) . "\">#$b</a>: ".htmlsanit($s{subject});
    }
}

my @blocks= split(/ /, $status{blocks});
if (@blocks && $status{"pending"} ne 'fixed' && ! length($status{done})) {
    for my $b (@blocks) {
        my %s = %{getbugstatus($b)};
        next if $s{"pending"} eq 'fixed' || length $s{done};
        push @descstates, "Blocking fix for <a href=\"" . bugurl($b) . "\">#$b</a>: ".htmlsanit($s{subject});
    }
}

if ($buglog !~ m#^\Q$gSpoolDir/db#) {
    push @descstates, "Bug is archived. No further changes may be made";
}

$indexentry .= join(";\n<br>", @descstates) . ".\n" if @descstates;
$indexentry .= "</h3>\n";

my $descriptivehead = $indexentry;

my $buglogfh;
if ($buglog =~ m/\.gz$/) {
    my $oldpath = $ENV{'PATH'};
    $ENV{'PATH'} = '/bin:/usr/bin';
    $buglogfh = new IO::File "zcat $buglog |" or &quitcgi("open log for $ref: $!");
    $ENV{'PATH'} = $oldpath;
} else {
    $buglogfh = new IO::File "<$buglog" or &quitcgi("open log for $ref: $!");
}


my @records;
eval{
     @records = read_log_records($buglogfh);
};
if ($@) {
     quitcgi("Bad bug log for $debbugs::gBug $ref. Unable to read records: $@");
}
undef $buglogfh;

=head2 handle_email_message

     handle_email_message($record->{text},
			  ref        => $bug_number,
			  msg_number => $msg_number,
			 );

Returns a decoded e-mail message and displays entities/attachments as
appropriate.


=cut

sub handle_email_message{
     my ($email,%options) = @_;

     my $output = '';
     my $parser = new MIME::Parser;
     # Because we are using memory, not tempfiles, there's no need to
     # clean up here like in Debbugs::MIME
     $parser->tmp_to_core(1);
     $parser->output_to_core(1);
     my $entity = $parser->parse_data( $email);
     my @attachments = ();
     display_entity($entity, $options{ref}, 1, $options{msg_number}, $output, @attachments);
     return $output;

}

=head2 bug_links

     bug_links($one_bug);
     bug_links($starting_bug,$stoping_bugs,);

Creates a set of links to bugs, starting with bug number
$starting_bug, and finishing with $stoping_bug; if only one bug is
passed, makes a link to only a single bug.

The content of the link is the bug number.

=cut

sub bug_links{
     my ($start,$stop,$query_arguments) = @_;
     $stop = $stop || $start;
     $query_arguments ||= '';
     my @output;
     for my $bug ($start..$stop) {
	  push @output,'<a href="'.bugurl($bug,'').qq(">$bug</a>);
     }
     return join(', ',@output);
}

=head2 handle_record

     push @log, handle_record($record,$ref,$msg_num);

Deals with a record in a bug log as returned by
L<Debbugs::Log::read_log_records>; returns the log information that
should be output to the browser.

=cut

sub handle_record{
     my ($record,$bug_number,$msg_number,$seen_msg_ids) = @_;

     my $output = '';
     local $_ = $record->{type};
     if (/html/) {
	  $output .= decode_rfc1522($record->{text});
	  # Link to forwarded http:// urls in the midst of the report
	  # (even though these links already exist at the top)
	  $output =~ s,((?:ftp|http|https)://[\S~-]+?/?)([\)\'\:\.\,]?(?:\s|\.<|$)),<a href=\"$1\">$1</a>$2,go;
	  # Add links to the cloned bugs
	  $output =~ s{(Bug )(\d+)( cloned as bugs? )(\d+)(?:\-(\d+)|)}{$1.bug_links($2).$3.bug_links($4,$5)}eo;
	  # Add links to merged bugs
	  $output =~ s{(?<=Merged )([\d\s]+)(?=\.)}{join(' ',map {bug_links($_)} (split /\s+/, $1))}eo;
	  # Add links to blocked bugs
	  $output =~ s{(?<=Blocking bugs)(?:(of )(\d+))?( (?:added|set to|removed):\s+)([\d\s]+)}
		      {(defined $2?$1.bug_links($2):'').$3.
			    join(' ',map {bug_links($_)} (split /\s+/, $4))}eo;
	  # Add links to reassigned packages
	  $output =~ s{(Bug reassigned from package \`)([^\']+)(' to \`)([^\']+)(')}
	  {$1.q(<a href=").pkgurl($2).qq(">$2</a>).$3.q(<a href=").pkgurl($4).qq(">$4</a>).$5}eo;
	  $output .= '<a href="' . bugurl($ref, 'msg='.($msg_number+1)) . '">Full text</a> and <a href="' .
	       bugurl($ref, 'msg='.($msg_number+1), 'mbox') . '">rfc822 format</a> available.';

	  $output = qq(<div class="msgreceived">\n<a name="$msg_number">\n) . $output . "</div>\n";
     }
     elsif (/recips/) {
	  my ($msg_id) = $record->{text} =~ /^Message-Id:\s+<(.+)>/im;
	  if (defined $msg_id and exists $$seen_msg_ids{$msg_id}) {
	       return ();
	  }
	  elsif (defined $msg_id) {
	       $$seen_msg_ids{$msg_id} = 1;
	  }
	  $output .= qq(<a name="$msg_number">\n);
	  $output .= 'View this message in <a href="' . bugurl($ref, "msg=$msg_number", "mbox") . '">rfc822 format</a>';
	  $output .= handle_email_message($record->{text},
				    ref        => $bug_number,
				    msg_number => $msg_number,
				   );
     }
     elsif (/autocheck/) {
	  # Do nothing
     }
     elsif (/incoming-recv/) {
	  my ($msg_id) = $record->{text} =~ /^Message-Id:\s+<(.+)>/im;
	  if (defined $msg_id and exists $$seen_msg_ids{$msg_id}) {
	       return ();
	  }
	  elsif (defined $msg_id) {
	       $$seen_msg_ids{$msg_id} = 1;
	  }
	  # Incomming Mail Message
	  my ($received,$hostname) = $record->{text} =~ m/Received: \(at (\S+)\) by (\S+)\;/;
	  $output .= qq|<p class="msgreceived"><a name="$msg_number"><a name="msg$msg_number">Message received</a> at |.
	       htmlsanit("$received\@$hostname") . q| (<a href="| . bugurl($ref, "msg=$msg_number") . '">full text</a>'.q|, <a href="| . bugurl($ref, "msg=$msg_number") . ';mbox=yes">mbox</a>)'.":</p>\n";
	  $output .= handle_email_message($record->{text},
				    ref        => $bug_number,
				    msg_number => $msg_number,
				   );
     }
     else {
	  die "Unknown record type $_";
     }
     return $output;
}

my $log='';
my $msg_num = 0;
my $skip_next = 0;
if (looks_like_number($msg) and ($msg-1) <= $#records) {
     @records = ($records[$msg-1]);
     $msg_num = $msg - 1;
}
my @log;
if ( $mbox ) {
     if (@records > 1) {
	  print qq(Content-Disposition: attachment; filename="bug_${ref}.mbox"\n);
	  print "Content-Type: text/plain\n\n";
     }
     else {
	  $msg_num++;
	  print qq(Content-Disposition: attachment; filename="bug_${ref}_message_${msg_num}.mbox"\n);
	  print "Content-Type: message/rfc822\n\n";
     }
     for my $record (@records) {
	  next if $record->{type} !~ /^(?:recips|incoming-recv)$/;
	  next if not $boring and $record->{type} eq 'recips' and @records > 1;
	  my @lines = split( "\n", $record->{text}, -1 );
	  if ( $lines[ 1 ] =~ m/^From / ) {
	       my $tmp = $lines[ 0 ];
	       $lines[ 0 ] = $lines[ 1 ];
	       $lines[ 1 ] = $tmp;
	  }
	  if ( !( $lines[ 0 ] =~ m/^From / ) ) {
	       my $date = strftime "%a %b %d %T %Y", localtime;
	       unshift @lines, "From unknown $date";
	  }
	  map { s/^(>*From )/>$1/ } @lines[ 1 .. $#lines ];
	  print join( "\n", @lines ) . "\n";
     }
     exit 0;
}

else {
     my %seen_msg_ids;
     for my $record (@records) {
	  $msg_num++;
	  if ($skip_next) {
	       $skip_next = 0;
	       next;
	  }
	  $skip_next = 1 if $record->{type} eq 'html' and not $boring;
	  push @log, handle_record($record,$ref,$msg_num,\%seen_msg_ids);
     }
}

@log = reverse @log if $reverse;
$log = join('<hr>',@log);


print "Content-Type: text/html; charset=utf-8\n\n";

my $title = htmlsanit($status{subject});

my $dummy2 = $debbugs::gWebHostBugDir;

print "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\">\n";
print "<HTML><HEAD>\n" . 
    "<TITLE>$short - $title - $debbugs::gProject $debbugs::gBug report logs</TITLE>\n" .
     '<meta http-equiv="Content-Type" content="text/html;charset=utf-8">'.
     "<link rel=\"stylesheet\" href=\"$debbugs::gWebHostBugDir/css/bugs.css\" type=\"text/css\">" .
    "</HEAD>\n" .
    '<BODY>' .
    "\n";
print "<H1>" . "$debbugs::gProject $debbugs::gBug report logs - <A HREF=\"mailto:$ref\@$gEmailDomain\">$short</A>" .
      "<BR>" . $title . "</H1>\n";

print "$descriptivehead\n";
print qq(<p><a href="mailto:$ref\@$debbugs::gEmailDomain">Reply</a> ),
     qq(or <a href="mailto:$ref-subscribe\@$debbugs::gEmailDomain">subscribe</a> ),
     qq(to this bug.</p>\n);
printf "<div class=\"msgreceived\"><p>View this report as an <a href=\"%s\">mbox folder</a>.</p></div>\n", bugurl($ref, "mbox");
print "<HR>";
print "$log";
print "<HR>";
print "<p class=\"msgreceived\">Send a report that <a href=\"/cgi-bin/bugspam.cgi?bug=$ref\">this bug log contains spam</a>.</p>\n<HR>\n";
print $tail_html;

print "</BODY></HTML>\n";

exit 0;
