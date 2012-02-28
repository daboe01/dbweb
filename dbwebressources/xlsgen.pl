#!/usr/bin/perl
use lib '/Users/boehringer/src/privatePerl';	#PropertyList (macos)
use lib '/home/hhb/src/privatePerl';			#linux
use lib '/srv/www/lib-perl';					#linux2
use TempFileNames;

# 11.5.05 by dr. boehringer


sub returnXLSForARRHR { my ($ret,$hr)=@_;
	use Spreadsheet::WriteExcel;
	
	my $tmpfilename=tempFileName('/tmp/dbweb','xls');
	my $workbook = Spreadsheet::WriteExcel->new($tmpfilename);
	my $format = $workbook->add_format();
	$format->set_bold();
	my $worksheet = $workbook->add_worksheet();
	
	my @cols= @$hr;
	my ($i,$j);
	# titelzeile in bold
	foreach my $currCol (@cols)
	{	$currCol=~s/\=//ogs;
		$worksheet->write(0, $j, $currCol, $format);
		$j++;
	}
	$i=1;
	foreach my $currRow   ( @{$ret} )
	{	$j=0;
		foreach my $currCol (@$currRow)
		{	$currCol=~s/\=//ogs;
			
			$worksheet->write($i, $j, $currCol);
			$j++;
		}	$i++;
	}
	
	$workbook->close();
	my $xls=readFile($tmpfilename);
	unlink($tmpfilename);
	$filename='Query.xls' unless $filename;
	%{$dbweb::apache->headers_out()} = ( 'Content-disposition' => 'attachment; filename='.$filename );
	$dbweb::apache->content_type('application/vnd.ms-excel');
	$dbweb::apache->print($xls);
	$dbweb::_isMuted=1;
}



sub returnXLSForSQLandDBH { my ($sql,$dbh,$filename)=@_;
	my $sth = $dbh->prepare( $sql );
	$sth->execute() || ( $dbweb::logger->log_error("$sql $DBI::errstr\n"));
	my $arrR=$sth->fetchall_arrayref();
	returnXLSForARRHR($arrR, $sth->{NAME});
}
