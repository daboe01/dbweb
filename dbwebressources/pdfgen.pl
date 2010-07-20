#!/usr/bin/perl
use lib qw{/Users/boehringer/src/privatePerl /Users/boehringer/bin /home/hhb/src/privatePerl /srv/www/lib-perl /HHB/bin};	#mac/linux
use TempFileNames;

# 11.5.05 by dr. boehringer

###################################
#
# workaround a recursion bug in perl (segmentation fault)
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

sub labelPrinter { my ($str, $objc)=@_;
	use Net::FTP;
	use Locale::Recode;
	my $tmpfilename=tempFileName('/tmp/dbweb', '');
	my $transcoder=Locale::Recode->new (from => 'ISO-8859-1', to => 'IBM437' );
	my $data= expandPDFDict($str, $objc);
	$transcoder->recode($data);
	writeFile($tmpfilename, $data);
	my $ftp = Net::FTP->new("10.210.98.254", Debug => 0) or warn "Cannot connect to host: $@";
	$ftp->login('xxxx');
	$ftp->put($tmpfilename,"LPT1");
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

use Net::FTP;
use passwordsecrets;

sub docscalFilesForPIZTypeAndDate { my ($piz,$type,$udate)=@_;
	my $ftp = Net::FTP->new("10.210.21.10", Debug => 0) or warn "Cannot connect to host: $@";
	   $ftp->login($imgname, $imgpassword);
	   $ftp->binary();

	my $spath;
	$spath='/Daten/DigitaleAkte/PatientenAkten/'.$1.'/'.$2.'/'.$3.'/'.$piz if $piz=~/^(..)(..)(..)/o;
	$udate=$1.'-'.$2.'-'.$3  if $udate =~/^([0-9]{4})-([0-9]{2})-([0-9]{2})/o;

	$ftp->cwd($spath);
	my @types=$ftp->ls();

	my @ret;
	foreach my $type (grep {/$type/} (@types))
	{	$ftp->cwd($spath.'/'.$type);
		my @files=$ftp->ls();
		foreach my $file (@files)
		{	my (undef, $date,$inst,$type)=split /_/o, $file;
#warn $file;
			my ($y,$m,$d)= $date =~/^(....)(..)(..)/o;
			$date="$y-$m-$d";
			if($date eq $udate)
			{	my $dfile='/www/data/tmp/'.$file;
				$dfile=~s/PDF$/pdf/o;
				$dfile=~s/JPG$/jpg/o;
				$ftp->get($file, $dfile) or warn "get failed ", $ftp->message;
				push(@ret,  {Date=>$date, type=>$type, path=>$dfile});
			}
		}
	} return \@ret;
}

