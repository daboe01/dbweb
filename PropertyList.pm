#	PropertyList.pm
#Mon Mar 23 18:21:16 MET 1998

package PropertyList;
require 5.000;
require Exporter;

@ISA       = qw(Exporter);
@EXPORT    = qw(&propertyFromString &stringFromProperty &quoteApostrophes &dequoteApostrophes);

$DEBUG = 0;

sub quoteApostrophes { my ($str, $c, $esc)=@_; $str=~s/$c/${esc}$c/g; return $str; }
sub dequoteApostrophes { my ($str, $c, $esc)=@_; $str=~s/\Q$esc$c\E/$c/g; return $str; }

sub quoteBackslashAndQuotes { my ($str) = @_; $str =~ s/(\"|\\)/\\$1/g; return $str; }
sub dequoteBackslash { my ($str) = @_; $str =~ s/\\(.)/$1/g; return $str; }

$stringRE='(?:([_\/\-a-zA-Z0-9.]+)|(?:\"((?:\\\\.)*(?:[^"\\\\]+(?:\\\\.)*)*)\"))';
#	this does not recocnize '\(\|'
#$stringRE='(?:([_\/\-a-zA-Z0-9.]+)|(?:\"((?:\\\\.)?(?:[^"\\\\]+(?:\\\\.)*)*)\"))';

$commentRE='\s*(/\*(.*?)\*/\s*)*';	# formerly '\s*'

# <!> position is inconsistent in some places
#	problem with calling subroutines before updating $options->{pos}

sub propertyFromStringReturningLength { my ($str, $options)=@_;
	my	($pos, $ret, $l) = (0);
	$l = 0;

	#	alpha-String <i> quoted escapes
	if ($str =~ /^${stringRE}${commentRE}/s)
	{	$l = length($&);
		$ret = defined($2)? dequoteBackslash($2): $1;
		print "Creating string:'$ret'\n" if ($DEBUG);
	} elsif	($str =~ /^\(${commentRE}/s)	# we encountered an array
	{	print "creating array [", $options->{pos} +  $pos, "]\n" if ($DEBUG);
		$l += $pos = length($&), $str = substr($str, $pos);
		$ret = [];
		while (!($str=~/^\)${commentRE}/s))
		{	($ret->[++$#$ret], $pos) = propertyFromStringReturningLength($str, $options);
			$str = substr($str, $pos), $l += $pos;
			$pos = length($&), $str = substr($str, $pos), $l += $pos
				if ($str=~/^${commentRE}\,${commentRE}/s);#<!> lacking ','
		}
		$l += length($&) if ($str=~/^\)${commentRE}/s);
		print "finished array [", $options->{pos} +  $pos, "]\n" if ($DEBUG);
	} elsif ($str=~/^\{${commentRE}/s)	# we encountered a dictionary
	{	my $name;
		$l += $pos = length($&), $str = substr($str, $pos);
		print "creating dict [", $options->{pos} + $pos, "]\n" if ($DEBUG);
		$ret = {};
		while (!($str=~/^\}\s*/s))
		{
			if ($str=~/^$stringRE\s*=${commentRE}/is)	# named property
			{	$l += $pos = length($&), $str = substr($str, $pos);
				$name = defined($2)? dequoteBackslash($2): $1;	#dequote if needed
				print "Reading name[$name] pos:", $options->{pos} +  $pos, " " if ($DEBUG);
				($ret->{$name}, $pos) = propertyFromStringReturningLength($str, $options);
				$str = substr($str, $pos), $l += $pos;
				$pos = length($&), $str = substr($str, $pos), $l += $pos
					if ($str=~/^${commentRE}\;${commentRE}/s);#<!> lacking ';'
			} else { badPlistHere($options->{pos} + $pos, $str); }
		}
		$l += length($&) if ($str=~/^\}${commentRE}/s);
		print "finished dict [", $options->{pos} +  $pos, "]\n" if ($DEBUG);
	} elsif ($str=~/^\<\s*/s)	# we encountered a data
	{	$pos = length($&);
		my ($dataStr, $i, $length);
		($dataStr) = ($str =~ /^.{$pos}([0-9a-hA-H ]+)>${commentRE}/s);
		$pos = length($&);
		badPlistHere($options->{pos} + $pos, $str, 'expecting data') if (!defined($dataStr));
		$dataStr =~ s{\s+}{}og;
		for ($i=0, $length=length($dataStr); $i<$length; $i+=2)
		{	$ret .= pack('H2', substr($dataStr, $i, 2));
		}
		$l = $pos;
	} else {
		badPlistHere($options->{pos} + $pos, $str);
	}
	badPlistHere($pos, $str) if ($l == 0);
	$options->{pos} += $pos;
	return ($ret, $l);
}

sub badPlistHere { my ($pos, $str, $desc)=@_;
	die "bad plist near pos:$pos POF[". substr($str, 0, 10), "] $desc";
}
sub badPlist { my ($pos, $strRef, $desc)=@_;
	die "bad plist near pos:$pos POF[". substr($$strRef, $pos, 10), "] $desc";
}
sub propertyFromStringRefPos { my ($str, $posRef, $options)=@_;
	my	($pos,$ret)=($$posRef);

	#	alpha-String <i> quoted escapes
	if ($$str=~/^.{$pos}${stringRE}${commentRE}/s)
	{	$pos = length($&);
		$ret = ($2 ne '')? dequoteBackslash($2): $1;
		print "creating string:'$ret'\n" if ($DEBUG);
	} elsif	($$str=~/^.{$pos}\(${commentRE}/s)	# we encountered an array
	{	$pos=length($&);
		print "creating array [$pos]\n" if ($DEBUG);
		$ret=[];
		while (!($$str=~/^.{$pos}\)${commentRE}/s))
		{	$ret->[++$#$ret]=propertyFromStringRefPos($str, \$pos, $options);
			$pos=length($&) if ($$str=~/^.{$pos}${commentRE}\,${commentRE}/s);	#<!> lacking ','
		}
		$pos=length($&) if ($$str=~/^.{$pos}\)${commentRE}/s);
		print "finished array [$pos]\n" if ($DEBUG);
	} elsif ($$str=~/^.{$pos}\{${commentRE}/s)	# we encountered a dictionary
	{	my $name;
		$pos=length($&);
		print "creating dict [$pos]\n" if ($DEBUG);
		$ret={};
		while (!($$str=~/^.{$pos}\}\s*/s))
		{	if ($$str=~/^.{$pos}$stringRE\s*=${commentRE}/is)	# named property
			{	$pos = length($&);
				$name = ($2 ne '')? dequoteBackslash($2): $1;	#dequote if needed
				print "reading name $name pos:$pos " if ($DEBUG);
				$ret->{$name} = propertyFromStringRefPos($str, \$pos, $options);
				$pos=length($&) if ($$str=~/^.{$pos}${commentRE}\;${commentRE}/s);#<!> lacking ';'
			} else { badPlist($pos, $str); }
		}
		$pos=length($&) if ($$str=~/^.{$pos}\}${commentRE}/s);
		print "finished dict [$pos]\n" if ($DEBUG);
	} elsif ($$str=~/^.{$pos}\<\s*/s)	# we encountered a data
	{	$pos=length($&);
		my ($dataStr, $i, $length);
		($dataStr)=($$str=~/^.{$pos}([0-9a-hA-H ]+)>${commentRE}/s);
		$pos=length($&);
		badPlist($pos, $str, 'expecting data') if (!defined($dataStr));
		$dataStr=~s{\s+}{}og;
		for ($i=0, $length=length($dataStr); $i<$length; $i+=2)
		{	$ret.=pack('H2', substr($dataStr, $i, 2));
		}
	} else {
		badPlist($pos, $str);
	}
	badPlist($pos, $str) if ($pos == $$posRef);
	$$posRef=$pos;
	return $ret;
}

sub propertyFromString { my($str, $options)=@_;
#	my $start=0;
#	return propertyFromStringRefPos(\$str, \$start, $options);
	my ($co) = {%{$options}, pos => 0 };
	my ($property, $length) = propertyFromStringReturningLength($str, $co);
	return $property;
}

$ScreenWidth = 120;
$tabWidth = 4;

sub wrapString { my ($str) = @_;
	return ($str =~ m{^([_\/\-a-zA-Z0-9.]+)$}os)? $str: '"'.$str.'"';
}

sub stringFromPropertyI { my($obj, $ident, $flags)=@_;
	my $str='';
	my ($in, $in_1)=("\t" x ($ident), "\t" x ($ident+1));

	if ( !ref($obj) )
	{	# determine data vs string
		if ($obj =~ m{[\x00-\x1f\x80-\x9f\x7f\xff]}o && !$flags->{noData})	# data encoding
		{	my ($i, $length);
			$str.='<';
			for ($i=0, $length=length($obj); $i<$length; $i++)
			{	$str.=' ' if ($i && !($i%4));
				$str.=unpack('H2', substr($obj, $i, 1));
			}
			$str.='>';
		} elsif (1 || !($obj=~/^([_\/\-a-zA-Z0-9.]+)$/os))	# OpenStep requires quoting
		{	$str.='"'.quoteBackslashAndQuotes($obj, '"', '\\').'"';
			print "Writing String:", quoteBackslashAndQuotes($obj), "\n" if ($DEBUG);
		} else { $str.= $obj; }
	} elsif ( ref($obj) eq 'ARRAY' )
	{	my $i;
		my $array = "(";
		for ($i=0; $i<=$#$obj; $i++)
		{	$array.=',' if ($i);
			$array.="\n".$in_1.stringFromPropertyI($obj->[$i], $ident+1, $flags);
		}
		$array .= "\n".$in.")";
		$array =~ s/\n/ /ogs, $array =~ s/\t//ogs
			if (length($array) + $ident * $tabWidth < $flags->{screenWidth} + ($array =~ /(\t)/ogs));
		$str .= $array;
	} elsif ( ref($obj) eq 'HASH' )
	{	my $hash = "{";
		foreach $key (keys(%{$obj}))
		{	next if (!defined($obj->{$key}));
			$hash.="\n".$in_1.wrapString($key)." = ".
				stringFromPropertyI($obj->{$key}, $ident+1, $flags).";";
		}
		$hash .= "\n".$in."}";
		$hash =~ s/\n/ /ogs, $hash =~ s/\t//ogs
			if (length($hash) + $ident * $tabWidth < $flags->{screenWidth} + ($hash =~ /(\t)/ogs));
		$str .= $hash;
	}
	return $str;
}

sub stringFromProperty { my($obj, $flags)=@_;
	my $myFlags = {%{$flags}};
	$myFlags->{screenWidth} = $ScreenWidth if (!defined($flags->{screenWidth}));
	stringFromPropertyI($obj, 0, $myFlags);
}

1;

# Convert:
#  pod2man --center "Genetics Lib" PropertyList.pm > /tmp/man3/PropertyList.3 ; man -M /tmp PropertyList

=head1 NAME

PropertyList.pm - A module for processing PropertyList files and data types

=head1 SYNOPSIS

 $property = propertyFromString($string);
 $string = stringFromProperty($property, $options);

=head1 DESCRIPTION

=head2 Definition of a PropertyList

A PropertyList is a Perl object being either a dictionary (hash), array (list) or string. A dictionary or array may contain any of the other data types (where the keys for dictionaries are strings).

=head2 String representations of PropertyLists

A string representation of a dictionary is enclosed in braces and represents entries of the dictionary as "key = value;". I<key> is a string and I<value> is the string representation of any of the allowed PropertyList data types.

Example for a dictionary:

 {
 	key = value;
 	dictionary = { key2 = anotherDictionary; };
 }

The string representations of arrays are enclosed in parantheses and seperated by commas.

Example of an array:

 ( string1, { dict = first; }, ( list, in , list), end )

A string is represented as a literal if it only contains characters from the following character class [_\/\-a-zA-Z0-9.]. Otherwise a string is enclosed into inverted commas. Inverted commas inside a string are escaped by a backslash.

Examples of strings:

 simpleString
 /a/path/which/needs/no/quoting
 "a more complex O'string"
 "\"inverted commas\" within a string"

Example of a more complex PropertyList:

 {
 	aList = ( { flag = 1; }, { flag = 2; } );
 	programOption1 = "do not print any insensible output";
 	"a key can be complex" = ( what, should, we, do,
 		( and, a, list, again) );
 }

Whitespace is used for option separation. C-comments starting in '/*' and ending in '*/' are permitted in positions where whitespace is allowed.

=head2 Use of the functions

The functions provided by this module are simply to switch between the two representations as either native Perl data types or strings. I<propertyFromString> will emit a I<die> when encountering a syntax error. I<stringFromProperty> take a hash I<options> which can be used to modify the formatting of the string representation. Without options any entry in either a dictionary or a list is placed on a separate line. You can set the value of I<screenWidth> within the array. In this case all entries of a dictionary or array are accumulated until they exceed the specified width. Should this happen, all entries are again split to one line each. This options helps to produce a compact on screen display of PropertyLists since this option works recursively, producing a single line only if the whole dictionary fits within.


