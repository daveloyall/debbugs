#!/usr/bin/perl -w

sub quit {
	my $msg = shift;
	print header . start_html("Error");
	print "An error occurred. Dammit.\n";
	print "Error was: $msg.\n";
	print end_html;
	exit 0;
}

sub abort {
	my $msg = shift;
	my $archive = shift;
	print header . start_html("Sorry");
	print "Sorry bug #$msg doesn't seem to be in the $archive database.\n";
	print end_html;
	exit 0;
}

sub htmlindexentry {
    my $ref = shift;
	my $archive = shift;

    my %status = getbugstatus($ref, $archive );
    my $result = "";

    if  ($status{severity} eq 'normal') {
        $showseverity = '';
    } elsif (grep($status{severity} eq $_, @debbugs::gStrongSeverities)) {
        $showseverity = "<strong>Severity: $status{severity}</strong>;\n";
    } else {
        $showseverity = "Severity: <em>$status{severity}</em>;\n";
    }

    $result .= "Package: <a href=\"" . pkgurl($status{"package"}) . "\"><strong>"
               . htmlsanit($status{"package"}) . "</strong></a>;\n"
                       if (length($status{"package"}));
    $result .= $showseverity;
    $result .= "Reported by: " . htmlsanit($status{originator});
    $result .= ";\nKeywords: " . htmlsanit($status{keywords})
                       if (length($status{keywords}));

    my @merged= split(/ /,$status{mergedwith});
    if (@merged) {
        my $mseparator= ";\nmerged with ";
        for my $m (@merged) {
            $result .= $mseparator."<A href=\"" . bugurl($m) . "\">#$m</A>";
            $mseparator= ", ";
        }
    }

    if (length($status{done})) {
        $result .= ";\n<strong>Done:</strong> " . htmlsanit($status{done});
    } elsif (length($status{forwarded})) {
        $result .= ";\n<strong>Forwarded</strong> to "
                   . htmlsanit($status{forwarded});
    } else {
        my $daysold = int((time - $status{date}) / 86400);   # seconds to days
        if ($daysold >= 7) {
            my $font = "";
            my $efont = "";
            $font = "em" if ($daysold > 30);
            $font = "strong" if ($daysold > 60);
            $efont = "</$font>" if ($font);
            $font = "<$font>" if ($font);

            my $yearsold = int($daysold / 364);
            $daysold = $daysold - $yearsold * 364;

            $result .= ";\n $font";
            $result .= "1 year and " if ($yearsold == 1);
            $result .= "$yearsold years and " if ($yearsold > 1);
            $result .= "1 day old" if ($daysold == 1);
            $result .= "$daysold days old" if ($daysold != 1);
            $result .= "$efont";
        }
    }

    $result .= ".";

    return $result;
}

sub pkgurl {
    my $ref = shift;
    my $params = "pkg=$ref";
    foreach my $val (@_) { 1 }
    
    return $debbugs::gCGIDomain . "pkgreport.cgi" . "?" . "$params";
}

%saniarray= ('<','lt', '>','gt', '&','amp', '"','quot');

sub htmlsanit {
    my $in = shift;
    my $out;
    while ($in =~ m/[<>&"]/) {
        $out.= $`. '&'. $saniarray{$&}. ';';
        $in=$';
    }
    $out .= $in;
    return $out;
}

sub bugurl {
    my $ref = shift;
    my $params = "bug=$ref";
    foreach my $val (@_) {
	$params .= "\&msg=$1" if ($val =~ /^msg=([0-9]+)/);
	$params .= "\&archive=yes" if ($val =~ /^archive=1/);
    }
	
    return $debbugs::gCGIDomain . "bugreport.cgi" . "?" . "$params";
}

sub packageurl {
    my $ref = shift;
    return $debbugs::gCGIDomain . "package.cgi" . "?" . "package=$ref";
}

sub allbugs {
    my @bugs = ();

    opendir(D, "$debbugs::gSpoolDir/db") || &quit("opendir db: $!");
    @bugs = sort { $a <=> $b }
		 grep s/\.status$//,
		 (grep m/^[0-9]+\.status$/,
		 (readdir(D)));
    closedir(D);

    return @bugs;
}

sub pkgbugs {
    my $pkg = shift;
	my $archive = shift;
	if ( $archive ) { open I, "<$debbugs::gSpoolDir/index.archive" || &quit("bugindex: $!"); } 
	else { open I, "<$debbugs::gSpoolDir/index.db" || &quit("bugindex: $!"); } 
    
    while(<I>) 
	{ 	if (/^$pkg\s+(\d+)\s+(.+)/)
		{ 	
		 	my $tmpstr = sprintf( "%d: %s", $1, $2 );
			$descstr{ $1 } = $tmpstr;
		}
    }
    return %descstr;
}

sub pkgbugsindex {
	my $archive = shift;
    my @bugs = ();
	if ( $archive ) { open I, "<$debbugs::gSpoolDir/index.archive" || &quit("bugindex: $!"); } 
	else { open I, "<$debbugs::gSpoolDir/index.db" || &quit("bugindex: $!"); } 
    while(<I>) { $descstr{ $1 } = 1 if (/^(\S+)/); }
    return %descstr;
}

sub maintencoded {
    my $input = $_;
	my $encoded = '';

    while ($input =~ m/\W/) 
	{ 	$encoded.=$`.sprintf("-%02x_",unpack("C",$&));
        $input= $';
    }
    $encoded.= $input;
    $encoded =~ s/-2e_/\./g;
    $encoded =~ s/^([^,]+)-20_-3c_(.*)-40_(.*)-3e_/$1,$2,$3,/;
    $encoded =~ s/^(.*)-40_(.*)-20_-28_([^,]+)-29_$/,$1,$2,$3/;
    $encoded =~ s/-20_/_/g;
    $encoded =~ s/-([^_]+)_-/-$1/g;
	return $input;
}
sub getmaintainers {
    my %maintainer;

    open(MM,"$gMaintainerFile") || &quit("open $gMaintainerFile: $!");
    while(<MM>) {
	m/^(\S+)\s+(\S.*\S)\s*$/ || &quit("$gMaintainerFile: \`$_'");
	($a,$b)=($1,$2);
	$a =~ y/A-Z/a-z/;
	$maintainer{$a}= $b;
    }
    close(MM);

    return %maintainer;
}

sub getbugstatus {
	my $bugnum = shift;
	my $archive = shift;

	my %status;

	if ( $archive )
	{	my $archdir = $bugnum % 100;
		open(S,"$gSpoolDir/archive/$archdir/$bugnum.status" ) || &abort("$bugnum", "archive" );
	} else
		{ open(S,"$gSpoolDir/db/$bugnum.status") || &abort("$bugnum"); }
	my @lines = qw(originator date subject msgid package keywords done
			forwarded mergedwith severity);
	while(<S>) {
		chomp;
		$status{shift @lines} = $_;
	}
	close(S);
	$status{shift @lines} = '' while(@lines);

	$status{package} =~ s/\s*$//;
	$status{package} = 'unknown' if ($status{package} eq '');
	$status{severity} = 'normal' if ($status{severity} eq '');

	$status{pending} = 'pending';
	$status{pending} = 'forwarded' if (length($status{forwarded}));
	$status{pending} = 'done'      if (length($status{done}));

	return %status;
}

sub buglog {
	my $bugnum = shift;
	my $archive = shift;
	if ( $archive )
	{	my $archdir = $bugnum % 100;
		return "$gSpoolDir/archive/$archdir/$bugnum.log";
	} else { return "$gSpoolDir/db/$bugnum.log"; }
}

1