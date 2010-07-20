#!/usr/bin/perl
use lib qw{/Users/boehringer/src/privatePerl /Users/boehringer/bin /home/hhb/src/privatePerl /srv/www/lib-perl /HHB/bin};	#mac/linux
use TempFileNames;

# 11.5.05 by dr. boehringer

###################################
#
# workaround a recursion bug in perl 5.8 (segmentation fault)
#
sub __expandPDFDict { my ($block,$dict)=@_;
	foreach my $key (keys %{$dict})
	{	if( ref($dict->{$key}) eq 'ARRAY' )
		{	$block =~s/<foreach:$key\b([^>]*)>(.+?)<\/foreach:$key>/__expandPDFForeachs($2, $dict->{$key}, $1)/iegs;
		} else
		{	$block =~s/<var:$key>/$dict->{$key}/iegs;
		} 
	} return $block;
}
# workaround a recursion bug in perl (segmentation fault)
sub __expandPDFForeachs { my ($block,$arr, $sepStr)=@_;
	my $sep;
	$sep=$1 if($sepStr=~/sep=\"(.*?)\"/ois);
	my @ret=map { __expandPDFDict($block,$_) } (@{$arr});
	@ret=grep { !/^\s*$/ } @ret;
	return join ($sep, @ret);
}
sub _expandPDFDict { my ($block,$dict)=@_;
	foreach my $key (keys %{$dict})
	{	if( ref($dict->{$key}) eq 'ARRAY' )
		{	$block =~s/<foreach:$key\b([^>]*)>(.+?)<\/foreach:$key>/__expandPDFForeachs($2, $dict->{$key}, $1)/iegs;
		} else
		{	$block =~s/<var:$key>/$dict->{$key}/iegs;
		} 
	} return $block;
}
# workaround a recursion bug in perl (segmentation fault)
sub _expandPDFForeachs { my ($block,$arr, $sepStr)=@_;
	my $sep;
	$sep=$1 if($sepStr=~/sep=\"(.*?)\"/ois);
	my @ret=map { _expandPDFDict($block,$_) } (@{$arr});
	@ret=grep { !/^\s*$/ } @ret;
	return join ($sep, @ret);
}
#
# end: workaround a recursion bug in perl (segmentation fault)
#
###################################

sub expandPDFDict { my ($block,$dict)=@_;
	foreach my $key (keys %{$dict})
	{	if( ref($dict->{$key}) eq 'ARRAY' )
		{	$block =~s/<foreach:$key\b([^>]*)>(.+?)<\/foreach:$key>/_expandPDFForeachs($2, $dict->{$key}, $1)/iegs;		# activate workaround
#<!>		$block =~s/<foreach:$key\b([^>]*)>(.+?)<\/foreach:$key>/expandPDFForeachs ($2, $dict->{$key}, $1)/iegs;		# without workaround
		} else
		{	$dict->{$key} =~s/([<>])/ \$$1\$ /igs;
			$block =~s/<var:$key>/$dict->{$key}/iegs;
		} 
	} return $block;
}
sub expandPDFForeachs { my ($block,$arr, $sepStr)=@_;
	my $sep;
	$sep=$1 if($sepStr=~/sep=\"(.*?)\"/ois);
	my @ret=map { expandPDFDict($block,$_) } (@{$arr});
	@ret=grep { !/^\s*$/ } @ret;
	return join ($sep, @ret);
}

sub provideTempFileName { my ($name)=@_;
	my $name2=$name;
	$name2=$2 if($name=~/(.*)\/([^\/]+)/o);
	my $tmpfilename=tempFileName('/tmp/dbweb',$name2);
	my $content=LWP::Simple::get($dbweb::pathPrefix.$dbweb::pathAddendum.'/'.$name);
	writeFile($tmpfilename, $content);
	return $tmpfilename;
}
sub copyTexToTemp { my ($name)=@_;
	my $name2;
	$name2=$2 if($name=~/(.*)\/([^\.]+)\.(.*)/o);
	writeFile('/tmp/'.$name2.'.'.$3, LWP::Simple::get($dbweb::pathPrefix.$name));
	return $name2;
}


sub PDFFilenameForTemplateAndRef { my ($str,$objc)=@_;
	if(ref($objc) eq 'ARRAY')
			{	$str =~s/<foreach>(.*?)<\/foreach>/expandPDFForeachs($1,$objc)/oegs }
	else 	{	$str = expandPDFDict($str,$objc)}
	$str =~s/<file:([^>]+)>/provideTempFileName($1)/oegs;
	$str =~s/<copytex:([^>]+)>/copyTexToTemp($1)/oegs;
#warn $str;
	my $tmpfilename=tempFileName('/tmp/dbweb','');
	writeFile($tmpfilename.'.tex',$str);
	$main::ENV{PATH} = '/usr/bin'; 								#untaint
	system('cd /tmp; /usr/bin/pdflatex --interaction=batchmode '.$tmpfilename.' >/dev/null');
	return $tmpfilename.'.pdf';
}

sub PDFForTemplateAndRef { my ($str,$objc)=@_;
	return readFile(PDFFilenameForTemplateAndRef($str,$objc) );
}


sub PDFForTemplateNameAndRef { my ($filename, $objc)=@_;
	my $str=LWP::Simple::get($dbweb::pathPrefix.$filename);
	return PDFForTemplateAndRef($str,$objc);
}
sub PDFFilenameForTemplateNameAndRef { my ($filename, $objc)=@_;
	my $str=LWP::Simple::get($dbweb::pathPrefix.$filename);
	return PDFFilenameForTemplateAndRef($str,$objc);
}
sub returnPDF { my ($data)=@_;
	$dbweb::apache->content_type('application/pdf');
	$dbweb::apache->print($data);
	$dbweb::_isMuted=1;
}

sub LPRPrint { my ($data, $printer, $copies, $options)=@_;
	my $prn="/usr/bin/lpr -P $printer -# "."$copies -o $options ";
	my $tmpfilename=tempFileName('/tmp/dbweb', '');
	writeFile($tmpfilename, $data );
	$main::ENV{PATH} = '/usr/bin'; 								#untaint

	system($prn.$tmpfilename);

}

sub applyDictToRTF { my ($dict,$rtf)=@_;
	while(my($key,$val)=each %{$dict} )
	{	$rtf =~s/\{\\\*\\bkmkstart $key\}\{\\\*\\bkmkend $key\}/$val/egs
	} return $rtf;
}

