#!/usr/bin/perl

# dbweb is a mvc-style database application server as of an apache module
# created 20.1.05 by dr. boehringer

# todo:
#	load bootstrap HTML from file if appropriate env is set.
#	whitelist for pk and perlfunc selection.

#
# dbweb application server
#######################################################
package dbweb;

# get access to PropertyList:
use lib qw{/srv/www/lib-perl /Users/daboe01/src/privatePerl /Users/boehringer/src/privatePerl /HHB/bin};
use PropertyList;
use TempFileNames;

#use strict;
use Apache2::Upload;
use Apache2::Request;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::Log;
use Apache2::ServerUtil;

use Apache::Session::File;
use Encode qw/decode is_utf8/;
use DBI;
use LWP::Simple;
use HTML::Entities;
use JSON::XS;
use Data::Dumper;
use DateTime;
#use DateTime::Format::DBI;
use POSIX;

# API
# data access and manipulation
#######################################################
package DG;

sub DBLoginState { my ($self)=@_;
	return dbweb::getGlobal('__dbloginerror__');
}
sub getRessource { my ($rsc)=@_;
	my $r=LWP::Simple::get($dbweb::pathPrefix.$dbweb::pathAddendum.'/'.$rsc);
	return $1 if($r =~/(.*)/os);	# untaint;
}
sub invokePerlfunc { my ($name, $param)=@_;
	my $paramCode='my $__invokeParam;';
	$paramCode.='$__invokeParam=\''.$param."'; " if $param;
	eval($paramCode.dbweb::getPerlfuncCode($name));
}

sub getGlobal { my ($name)=@_;
	return dbweb::getGlobal($name);
}
sub setGlobal { my ($dict)=@_;
	dbweb::setGlobal($dict);
}

sub registerPerlmodule { my ($str)=@_;
	$str->import;
}

sub insertDict { my ($self,$dict)=@_;
	$dict->{$self->{bindFromColumn}}=dbweb::selectedIDOfDisplayGroupName($self->{bindToDG})
		if(defined $self->{bindFromColumn} && defined $self->{bindToDG} && !length $dict->{$self->{bindFromColumn}} );
	map  { delete $dict->{$_} } (@{ $self->{suppress_insert} }) if(defined $self->{suppress_insert});
#use Data::Dumper;
#warn Dumper($dict);
	return dbweb::insertDictIntoTable ( dbweb::getDBHForDG($self),$dict,length $self->{write_table}? $self->{write_table}:$self->{table}, $self->{types}, $self->{primaryKey} );
}
sub insertDictUsingFilter { my ($self,$dict,$filter)=@_;
	my $additionalAttribs=dbweb::whereClauseForFilterOfDGName($filter,dbweb::nameOfDG($self) );
	my $templateDict=$self->selectedDict();		#<!> bug: breaks upon empty selection
	$dict->{$_}=$templateDict->{$_} for (keys %{ $additionalAttribs });
	return $self->insertDict($dict);
}
sub updatePKWithDict { my ($self, $pk, $dict, $options)=@_;
	for ( keys %{$dict} )
	{	$dict->{$_}=\$dbweb::globalNullObject unless defined $dict->{$_};
	}
	return dbweb::updateAttriutesOfDGNForWhereClause( $dict, dbweb::nameOfDG($self), {$self->{primaryKey}=>$pk}, undef, $options, $self->{types});
}
sub updateSelectionWithDict { my ($self, $dict, $options)=@_;
	return $self->updatePKWithDict($self->selectedPK() , $dict, $options);
}
sub deletePK { my ($self, $pk)=@_;
	my $dbh=dbweb::getDBHForDG($self);
	dbweb::removeRowsForWhereClause($dbh,(length $self->{write_table})? $self->{write_table}:$self->{table}, {$self->{primaryKey}=>$pk}, $self->{types}) if($dbh);
	dbweb::removeWhereDictFromCache($self,{$self->{primaryKey}=>$pk}) if($self->{cache});
	$self->invalidateSelection();
}

sub deleteForWhereClauseDictRaw { my ($self, $dict)=@_;
	my $name=dbweb::nameOfDG($self);
	my $dbh=dbweb::getDBHForDG($self);
	removeRowsForWhereClause($dbh,(length $self->{write_table})? $self->{write_table}:$self->{table}, $dict) if($dbh);
	removeWhereDictFromCache($self,$dict) if($self->{cache});
	sessionData('selectedID_'.$dgName, '');
	invalidateDisplayGroupsDependingOnDGName($dgName);
}

sub floatValue { my ($self,$path)=@_;
	my $val=$self->dictForPK($path)->{Value};
	$val=~ s/,/\./o;
	return $val;
}

sub valueOfPath { my ($self, $path, $format)=@_;
	my $name=dbweb::nameOfDG($self);
	$path=$name.'.'.$path unless($path=~/\./o);

	my $pk=$self->selectedPK();
	my $pkname;
	($path,$pkname)=($1,$2) if($path =~/([^\@]+)\@(.*)/ );	#<dg.field@  foreignKey>
	$pk=dbweb::lookupDataForPathAndPK($name.'.'.$pkname, $self->selectedPK() ) if(length $pkname);
	return undef unless length $pk;
	return dbweb::formatDataField($name, undef, dbweb::lookupDataForPathAndPK($path, $pk), $format)  if($format);
	return dbweb::lookupDataForPathAndPK($path, $pk );
}

sub hasSelection { my ($self)=@_;
	my $displayGroupName=dbweb::nameOfDG($self);
	return 1 if(length dbweb::selectedIDOfDisplayGroupName($displayGroupName));
	return 0;
}

sub selectedPK { my ($self, $opts)=@_;
	my $displayGroupName=dbweb::nameOfDG($self);

	unless(length dbweb::selectedIDOfDisplayGroupName($displayGroupName)) 	# e.g. call from _earlyauto_ when handleForeachs did not set  the selectedID yet
	{	dbweb::boostSelectionForDGN($displayGroupName, $opts) if($opts->{boost});
	}
	return dbweb::selectedIDOfDisplayGroupName($displayGroupName);
}
sub selectedDict { my ($self,$opts)=@_;
	if($self->{DataInSession})
	{	my $dicts= $self->dictsForWhereClauseDictRaw( {}, $opts );
		return $dicts? $dicts->[0]: undef;
	}
	my $pk=$self->selectedPK($opts);
	return (length $pk)? $self->dictForPK($pk): undef;
}

sub _dictsForRows { my ($self,  $arr,  $utf8)=@_;
	return undef if(!$arr || $#{$arr}==-1);
	my @cols=@{$self->{columns}};
	my @ret=map
	{	my $ddict;
		for(my $i=0; $i <= $#cols; $i++)
		{	my $val=$_->[$i];
			if($utf8)
			{	my $transcoder=$dbweb::_dbhE{dbweb::getDBHForDG($self)};
				Encode::_utf8_off($val);
				Encode::from_to(  $val, $transcoder->{encoding}, 'utf8');
				Encode::_utf8_on( $val);
			}
			$ddict-> {$cols[$i]}=$val;
		}
		$ddict;
	} (@{$arr});
	return \@ret;
}

sub dictsForWhereClauseDictRaw { my ($self,$dict,$opts, $utf8)=@_;
	my $erg=$self->_dictsForRows(dbweb::getRawDataForDG($self, $dict,$opts), $utf8);
	return $erg if(length $erg && $#{$erg}>-1);
	return undef;
}

sub dictForPK { my ($self,$pk)=@_;
	my $dicts= $self->dictsForWhereClauseDictRaw( { $self->{primaryKey}=>$pk } );
	return $dicts? $dicts->[0]:undef;
}
sub valueOfSelectedField { my ($self, $path)=@_;
	my $name=dbweb::nameOfDG($self);
	return dbweb::lookupDataForPathAndPK($name.'.'.$path, $self->selectedPK() );
}

sub allDicts { my ($self)=@_;
	return $self->_dictsForRows(dbweb::getDataForDGN(dbweb::nameOfDG($self)));
}
sub dictsForWhereClauseDict { my ($self,$dict)=@_;
	return $self->_dictsForRows($self->rowsForWhereClauseDict($dict));
}
sub rowsForWhereClauseDict { my ($self,$dict)=@_;
	return dbweb::getDataForDGN(dbweb::nameOfDG($self), {whereClause => $dict}) ;
}
sub rowsForFilterArray { my ($self,$arr)=@_;
	return dbweb::getDataForDGN(dbweb::nameOfDG($self), {whereClause => dbweb::whereClauseForFilterArray($arr)}) ;
}
sub dictsForFilter { my ($self,$filter)=@_;
	return $self->dictsForWhereClauseDict ( dbweb::whereClauseForFilterOfDGName($filter,dbweb::nameOfDG($self) ) ) ;
}

sub setFilterToArray{ my ($self,$filter,$arr)=@_;
	$self->{filters}->{$filter}=$arr;
}
sub deleteFilter{ my ($self,$filter)=@_;
	delete $self->{filters}->{$filter};
}

sub hasWhere { my ($self)=@_;
	if(defined $dbweb::displayGroups->{$self->{bindToDG}}) { return 1 }
	else { return dbweb::sessionData('haswhere_'.$self->{bindToDG} ) }
}
sub setWhere { my ($self, $dict)=@_;
	if(exists $dbweb::displayGroups->{$self->{bindToDG}} && $dbweb::displayGroups->{$self->{bindToDG}}->{DataInSession})
	{	dbweb::sessionData('session_'.$self->{bindToDG},$dict );
	} else
	{	dbweb::sessionData('where_'.$self->{bindToDG}, $dict );
	}
	$self->invalidateSelection();
	dbweb::sessionData('haswhere_'.$self->{bindToDG}, $dict?1:0) unless exists $dbweb::displayGroups->{$self->{bindToDG}};
}

sub clearCache { my ($self)=@_;
	dbweb::sessionData('cache_'.dbweb::nameOfDG($self), '');
}
sub loadCacheFromDGWithPKs { my ($self,$loader,$arr)=@_;
	my %pkhash;
	$self->clearCache();
	for(@{$arr})
	{	$pkhash{$_}='',dbweb::insertDictIntoCache($self,$loader->dictForPK($_)) unless defined $pkhash{$_}
	};
}
sub copyCacheFromDG { my ($self,$loader)=@_;
	$self->clearCache();
	dbweb::insertDictIntoCache($self,$_) for (@{$loader->dictsForWhereClauseDictRaw({})});
}
sub loadCacheFromDG { my ($self,$loader)=@_;
	$self->clearCache();
	dbweb::insertDictIntoCache($self,$_)  for ( @{ $loader->allDicts() } );
}
sub appendDictToCache { my ($self,$loader)=@_;
	dbweb::insertDictIntoCache($self,$loader);
}

sub _flattenArrUsingFaceAndDelim { my ($self,$arr,$face,$delim,$sort)=@_;
	my $name=dbweb::nameOfDG($self);
	my @arr2= grep { length $_ } map
	{	my $val;
		if($face =~/([^\@]+)\@(.*)/ )		#<dg.field@  foreignKey>
		{ 	my ($path,$pkname)=($1,$2);
			my $pk=$_->{$pkname};
			$val=dbweb::lookupDataForPathAndPK($path, $pk ) if(length $pk);
		} else
		{	if(ref $face eq 'ARRAY')
			{	my $r=$_;
				my @faces=map { $r->{$_} } grep { length $r->{$_} } (@$face);
				$val=$faces[0];
			} else
			{	$val=$_->{$face}
			}
		}
	} ( @{$arr} );
	@arr2=sort @arr2 if($sort);
	return join($delim, @arr2);
}
sub flattenFilterUsingFaceAndDelim { my ($self,$filter,$face,$delim,$sort)=@_;
	my $arr=$self->dictsForFilter($filter);
	return $self->_flattenArrUsingFaceAndDelim($arr,$face,$delim,$sort);
}

sub flattenForFaceAndDelim { my ($self,$face,$delim,$sort)=@_;
	my $arr=$self->allDicts();
	return $self->_flattenArrUsingFaceAndDelim($arr,$face,$delim,$sort);
}

sub cacheIsLoaded { my ($self)=@_;
	my $cache=dbweb::sessionData('cache_'.dbweb::nameOfDG($self));
	return 0 unless length $cache;
	return 1 if($#{$cache}>=0);
	return 0;
}

sub performUndo {my ( $self)=@_;
	my $udg=dbweb::getUndoDGForDG($self);
	my $cnt=dbweb::getDataForDGN(dbweb::nameOfDG($udg),{countOnly => 1})->[0]->[0];
	return unless $cnt;
	my $r=$udg->dictsForWhereClauseDictRaw({},{offset=>$cnt-1, limit=>1});	# get timestamp of last row (<!>enforce sorting by timestamp)
	my $timestamp=$r->[0]->{timestamp};
	my $actions=$udg->dictsForWhereClauseDictRaw({timestamp=>$timestamp});	# fetch the transaction to undo
	for(@$actions)
	{	my $dg=$dbweb::displayGroups->{$_->{dg}};
		if($_->{action} eq 'update')
		{	$dg->updatePKWithDict($_->{pk}, dbweb::propertyFromString($_->{oldvals}));
		} elsif($_->{action} eq 'insert')
		{	$dg->deletePK($_->{pk});
		} elsif($_->{action} eq 'delete')
		{	$dg->insertDict(dbweb::propertyFromString($_->{oldvals}));
		}
	} $udg->deletePK($timestamp);
}

# http redirection
#######################################################
sub redirectToAppDGPK{ my ($app,$tdg,$pk)=@_;
	dbweb::activateApplication($app, '&a=select&dg='.$tdg.'&pk='.$pk.'&cs=1');
}
sub redirectTo{ my ($self,$loc)=@_;
###	warn "redirecting to ".$loc;
	dbweb::activateApplication($loc);
}
sub redirectToValueOfSelectedField{ my ($self,$field)=@_;
	$self->redirectTo($self->valueOfSelectedField($field));
}
sub rejectLogin{
	dbweb::loginerror();
}

# basic date / time
#######################################################
sub currentTimeString{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime;
	$year+=1900;$mon+=1;
	return "$year-$mon-$mday $hour:$min:$sec";
}
sub currentDateString{
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime;
	$year+=1900;$mon+=1;
	return sprintf('%04d-%02d-%02d',$year,$mon,$mday);
}

# raw access
#######################################################
sub executeSQLStatement { my ($self, $sql,$nofetch)=@_;
	my $dbh=dbweb::getDBHForDG($self);
	my $enc=$dbweb::_dbhE{$dbh}->{encoding};
	my $sth = $dbh->prepare( $sql );
	$sth->execute() || ($dbweb::SQLDEBUG && $dbweb::logger->log_error("$sql $DBI::errstr\n"));
	$dbweb::dbi_error=$DBI::errstr unless $dbweb::dbi_error;
	return if $nofetch;
	my $rowarrref;
	my $ret=[];

	while($rowarrref=$sth->fetchrow_arrayref() )
	{	my @currRow= map { (length $dbweb::_dbhE{$dbh}->{encoding})? Encode::decode($enc, $_): $_ } @{$rowarrref};
		push(@{$ret},\@currRow);
	} return $ret;
}
sub dbh { my ($self) = @_; return dbweb::getDBHForDG($self); }

# set selection
#######################################################
sub invalidateSelection{ my ($self)=@_;
	$self->selectPK('');
}

sub selectPK{ my ($self,$pk)=@_;
	dbweb::sessionData('selectedID_'.dbweb::nameOfDG($self), $pk);
	dbweb::invalidateDisplayGroupsDependingOnDGName(dbweb::nameOfDG($self));
}
# make selection visible in livegrid
#sub makeSelectionVisible{ my ($self)=@_;
#	my $pks= dbweb::getRawDataForDG($self, $self->{primaryKey} );
#	my $selID= $self->selectedPK();
#	my ($i,$currID);
#	for my $currID (@$pks)
#	{	last if $currID eq $selID;
#		$i++;
#	}
#	return $currID eq $selID? $i:undef
#}

# transaction
#######################################################
sub startTransaction{ my ($self)=@_;
		$self->dbh->{RaiseError} = 1; # raise exception if an error occurs
		$self->dbh->{AutoCommit} = 0; # disable auto-commit
}
sub commitTransaction{ my ($self)=@_;
		$self->dbh->commit;
}
sub rollbackTransaction{ my ($self)=@_;
		$self->dbh->rollback;
}

# ui
#######################################################
sub _removeFromSnapshots{ my ($dgn, $name)=@_;
 	my $key;
	foreach $key (keys(%dbweb::session))
	{	if ($key=~/^forminfo_$dgn.*?$dbweb::APPNAME$/)
		{	my $snap=$dbweb::session{$key}->{snapshot};
			delete $snap->{$name} if(exists  $snap->{$name});
		}
	}
}
sub _disableButton{ my ($button, $template2)=@_;
	$$template2=~s/<input type=\"button\" value=\"$button\"/<input type=\"button\" disabled value=\"$button\"/gs;
}
sub _disableUIElement{ my ($self, $button, $template2)=@_;
	my $dgn=dbweb::nameOfDG($self);
	my $name=$dgn.'_'.$button;

	$$template2=~s/<select name=\"$name\"/<select disabled/gs;
	$$template2=~s/(<input\s+type=[^\s]+)\s+name=\"$name\"/$1 disabled/gs;
#<!> needs fix: s/(<input\s+type=[^\s]+)([^>]+)name=\"$name\"/$1$2 disabled/gs;	# untested
	_removeFromSnapshots($dgn, $button);
}
sub _removeUIElement { my ($self, $button, $template2)=@_;
	$template2=\$template  unless defined $template2;
	my $dgn=dbweb::nameOfDG($self);
	my $name=$dgn.'_'.$button;
	$$template2=~s/<select name=\"$name\"[^>]+>//gs;
	$$template2=~s/<input\s+type=[^>]+?name=\"$name\"[^>]+>//gs;
	$$template2=~s/<label for=\"$name\">.*?<\/label>//gs;
	_removeFromSnapshots($dgn, $button);
}
sub addUserscript { my ($script)=@_;
	$dbweb::JSConfigs{userscripts}->{$script}='';
}

sub detach_async { my ($cmd)=@_;
#	use ModPerl2::Tools;
#	ModPerl2::Tools::spawn +{survive=>1}, $cmd;
# <!> gen. wrapperscript in tmp that generates semaphore after $cmd finished
}


# end api
###############################################


package dbweb;

#
# global variables in session
###############################################
sub getGlobal { my ($name)=@_;
	my $data=dbweb::sessionData('GLOBAL');
	return $data->{$name} if(length  $data);
	return undef;
}
sub setGlobal { my ($dict)=@_;
	my $data=dbweb::sessionData('GLOBAL');
	$data={} unless length $data;
	$data->{$_}=$dict->{$_}	for ( keys(%{$dict}) );
	dbweb::sessionData('GLOBAL',$data);
}

#
# db abstraction
###############################################

sub DBType { my ($key,$types)=@_;
	my $typesMapper={ 'int' => DBI::SQL_TYPE_INTEGER, 'date' => DBI::SQL_TYPE_TIMESTAMP, 'real' => DBI::SQL_REAL, 'time' => DBI::SQL_TYPE_TIMESTAMP, 'bool' => DBI::SQL_BOOLEAN};
	return $typesMapper->{$types->{$key}} if(exists $types->{$key});
	return DBI::SQL_VARCHAR;
}
sub dateObjectForString { my ($str)=@_;
	return DateTime->new($1,$2,$3,$4,$5,$6) if ($str=~ /([0-9]+)-([0-9]+)-([0-9]+) ([0-9]+):([0-9]+):([0-9]+)/o);
	return DateTime->new($1,$2,$3) if ($str=~/^([0-9]+)-([0-9]+)-([0-9]+)$/o);
}

sub pushDBParam { my ($params, $key, $val, $types, $transcoder)=@_;
	$key =~s/__alias__[0-9]+//o;
	if (!dbweb::isNull($val) && DBType($key, $types)==DBI::SQL_VARCHAR)
	{	Encode::_utf8_on($val);
		$val=Encode::encode($transcoder->{encoding}, $val);
		Encode::_utf8_off($val);
	}
	$val= $transcoder->{dateformatter}->format_datetime(dateObjectForString($val)) if (0&& (length $transcoder->{dateformatter}) && DBType($key, $types) == DBI::SQL_TYPE_TIMESTAMP);
	push @{$params}, { val=> dbweb::isNull($val)? undef:$val, type=> DBType($key, $types) };
###	warn "dict1: $key, $val";
	return '?';
}
sub whereclauseTemplateForDict { my ($dict, $types, $likes, $params, $transcoder, $opts)=@_;
	return '' unless (keys(%{$dict}));

	my ($currKey,@retarr);
	my $literalIndicator;
	foreach $currKey (keys(%{$dict}))
	{	my 	($val,$op)= ($dict->{$currKey},'=');

		if(exists $likes->{$currKey})
		{	$op='::text~*';
		} elsif(ref($val) eq 'HASH')
		{	if($val->{op} eq 'literal')
			{	$op =$val->{val};
				$val=\$literalIndicator;
			} else
			{	($val,$op)=($val->{val}, $val->{op})
			}
		}
		if(dbweb::isNull($val))
		{	push(@retarr, $dbweb::SQL_TQL.$currKey."$dbweb::SQL_TQR ". (($op eq '=')? 'IS NULL':'IS NOT NULL'));
		} else
		{	push(@retarr, $dbweb::SQL_TQL.$currKey."$dbweb::SQL_TQR ".$op.($val==\$literalIndicator? '' : pushDBParam($params, $currKey, $val, $types, $transcoder) ));
		}
	}
	my $retstr= join(' AND ', @retarr);
	$retstr =~s/__alias__[0-9]+//o;
	if($dbweb::SQL_LIMIT==1)
	{	$retstr.=' rownum>= '.$opts->{offset}.' and rownum <= '.($opts->{limit}+$opts->{offset}) if $opts && $opts->{limit};
	}
	return '' unless $retstr;
	return ' WHERE '.$retstr;
}

sub executeSQLTemplate { my ($dbh, $command, $suffixStr, $dict1, $whereClause, $opts)=@_;
	my ($types, $likeSearch)=($opts->{types},$opts->{like});
	my $params=[];
	my $transcoder=$dbweb::_dbhE{$dbh};
	if($dict1)
	{	foreach my $currKey (sort keys(%{$dict1})) 
		{	pushDBParam($params, $currKey, dbweb::isNull($dict1->{$currKey})? undef: $dict1->{$currKey}, $types, $transcoder);
		}
	}
	my $wheretempl= whereclauseTemplateForDict($whereClause,$types,$likeSearch, $params, $transcoder, $opts);
	my $sql=$command. $wheretempl. $suffixStr;
	$sql='select count(*) from('.$sql.') '.$dbweb::SQL_CP if $opts->{countOnly};
#warn $sql if $opts->{countOnly};

	if($dbweb::SQL_LIMIT==0)
	{	$sql.=' LIMIT '.$opts->{limit}.' OFFSET '.((length $opts->{offset})? $opts->{offset}:'0') if $opts->{limit};
	}
	if( $dbweb::SQLDEBUG==2 && !($sql =~/^SELECT/ogi) )
	{	$dbweb::logger->log_error($sql);
		$dbweb::logger->log_error('params: '.dbweb::stringFromProperty($dict1));
		$dbweb::logger->log_error('where: '. dbweb::stringFromProperty($whereClause));
	}
	my $sth = $dbh->prepare ( $sql );

  	my ($i, $currval);
	foreach $currval (@$params)
	{	if( $currval->{type} == DBI::SQL_BOOLEAN)
		{	$currval->{val}= ($currval->{val}=~/f/io)?0:1 unless($currval->{val}=~/[0-1]/o);
		}
		$sth->bind_param(++$i, $currval->{val}, $currval->{type} );
###		$dbweb::logger->log_error("$currval->{val} ");
	}
	$sth->execute() || ($dbweb::logger->log_error("$sql: $DBI::errstr\n") );
	$dbweb::dbi_error=$DBI::errstr unless $dbweb::dbi_error;
	return $sth;
}

# update
sub updateAttriutesOfTableForWhereClause { my ($dbh, $dict1, $table, $whereClause, $types)=@_;
	my $valstempl = join(',  ', map { $dbweb::SQL_TQL.$_.$dbweb::SQL_TQR.'= ?' } sort keys(%{$dict1}));
	return unless $valstempl;
	executeSQLTemplate($dbh,"UPDATE $dbweb::SQL_TQL".$table."$dbweb::SQL_TQR set ". $valstempl, undef, $dict1, $whereClause, {types=>$types});
}

# delete
sub removeRowsForWhereClause { my ($dbh,$table, $whereClause, $types)=@_;
	executeSQLTemplate($dbh,"DELETE FROM $dbweb::SQL_TQL".$table."$dbweb::SQL_TQR ", undef, undef, $whereClause, {types=>$types});
}

# fetch
sub getColumnsOfTableForDict { my ($dbh, $cols, $table, $whereClause, $opts)=@_;
	my $sortarr=$opts->{sort};

	my $attrib=join (', ', map { $dbweb::SQL_TQL.$_.$dbweb::SQL_TQR } @{$cols} ) ;
	my $orderByStr;

	$orderByStr = ' ORDER BY '. ( join(', ', map {    ref($_) eq 'HASH'
		? (length($_->{literal})? $_->{literal}: $dbweb::SQL_TQL.$_->{col}.$dbweb::SQL_TQR."  $_->{op}")
		: $dbweb::SQL_TQL.$_.$dbweb::SQL_TQR } (@{$sortarr}))) if($#{$sortarr} != -1);

	my $sth = executeSQLTemplate($dbh,'SELECT '.$attrib.' FROM '.$dbweb::SQL_TQL.$table.$dbweb::SQL_TQR.' ', $orderByStr, undef, $whereClause, $opts);
 	my $rowarrref;
	my $ret=[];

	while($rowarrref=$sth->fetchrow_arrayref() )
	{
	#	my @currRow= map { (length $dbweb::_dbhE{$dbh}->{encoding})? Encode::decode($dbweb::_dbhE{$dbh}->{encoding}, $_): $_ } @{$rowarrref};
		my @currRow=@{$rowarrref};
		push(@{$ret},\@currRow);
	}
	$dbweb::logger->log_error("did fetch from $table ($#{$ret})") if($dbweb::SQLDEBUG==1);
	return $ret;
}


sub isNull { my ($val)=@_;
	return ref($val) && $val==\$dbweb::globalNullObject;	# semantics are from "higher order perl"
}


# insert
sub insertDictIntoTable { my ($dbh,$dict,$table,$types,$pk)=@_;
	delete $dict->{$_} for grep {!length $_} keys %{$dict};
	my @cols= sort keys %{$dict};
	my $colstr=join (', ', map { $dbweb::SQL_TQL.$_.$dbweb::SQL_TQR }  @cols );
	my $templatestr = join(', ', map { '?' } @cols );

	executeSQLTemplate($dbh,'INSERT INTO '.$dbweb::SQL_TQL.$table.$dbweb::SQL_TQR.' ('.$colstr.') VALUES ('.$templatestr.')', undef, $dict, undef, {types=>$types});
	return $dbh->last_insert_id(undef, undef, $table, $dbweb::SQL_TQL. $pk. $dbweb::SQL_TQR);
}

sub evalCacheCriteriaInDGForWhereClause { my ($displayGroup, $whereClause)=@_;
	my (%dict,$ret);
	$dict{getIndexOfColumnInDG($_,$displayGroup)}=$whereClause->{$_} for ( keys %{$whereClause} );
	for ( keys %dict )
	{	if (ref($dict{$_}) eq 'HASH' )
		{	if(isNull($dict{$_}->{val}) )
			{	$ret.='$a->['.$_.'] '.$dict{$_}->{op}." ''".' && '} else
			{	$ret.='$a->['.$_.'] '.$dict{$_}->{op}.$dict{$_}->{val}.' && '}
		} else
		{	if(isNull( $dict{$_}) )
			{ $ret.='!(length $a->['.$_.']) && '} else
			{ $ret.='$a->['.$_.'] eq \''.$dict{$_}.'\' && '}
		}
	}
	$ret =~s/ && $//o;
	$ret='1' unless(length $ret);
	$ret=$1 if($ret =~ /(.*)/os);	# untaint
	return 'sub { my ($a)=@_; '.$ret.' };';
}

sub getColumnsFromCacheForDGNAndDict { my ($dbh, $displayGroupName, $whereClause, $sortArr, $opts)=@_;
	my $displayGroup=$dbweb::displayGroups->{$displayGroupName};
	my $data= ( (exists $displayGroup->{data})? $displayGroup->{data} : sessionData('cache_'.$displayGroupName) );
	if($data && $#{$data}>=0)
	{	my $code=evalCacheCriteriaInDGForWhereClause($displayGroup,$whereClause);
		my $coderef=eval $code;  $dbweb::logger->log_error("$code:$@")  if(length $@);
		my @myarr=grep { $coderef->($_) } @{$data} ;
		if($opts->{countOnly})
		{	my $cnt= scalar @myarr;
			return [[$cnt]];
		} elsif( $opts->{limit} > 0)	#<!> seems to break conditions (for yet unknown reasons)
		{	my ($offset,$limit) = ($opts->{offset},$opts-> {limit});
			my $last =(scalar @myarr);
			$last=($offset+$limit> $last)? $last: $offset+$limit;
			return [@myarr[$offset..$last-1]];
		}
		return \@myarr;
	}
	return [] unless($dbh);
	my $ret=getColumnsOfTableForDict($dbh,$displayGroup->{columns},$displayGroup->{table}, undef, {sort=>$sortArr, types=>$displayGroup->{types} });
	if($#{$ret} >= 0)
	{	sessionData('cache_'.$displayGroupName,$ret);
		return getColumnsFromCacheForDGNAndDict($dbh,$displayGroupName, $whereClause, $sortArr,$opts);
	}
	return [];
}


sub sessionData{ my ($key,$val)=@_;
	$key.='_'.$dbweb::APPNAME unless ($key =~/^(session_|GLOBAL)/o );
	unless(defined $val)
	{	return $dbweb::session{$key}
	} else
	{	$dbweb::session{$key}=$val;
	}
}

sub registerDisplayGroups { my ($format, $dgstr)=@_;
	my $dg= ($format=~/json/oi)? JSON::XS->new->ascii->decode($dgstr): dbweb::propertyFromString($dgstr);
	for(keys %$dg)
	{	if(exists $dbweb::displayGroups->{$_})
		{	my $dgName=$_;
			$dbweb::displayGroups->{$dgName}->{$_}=$dg->{$dgName}->{$_} for keys %{$dg->{$dgName}};
		} else
		{	$dbweb::displayGroups->{$_}=$dg->{$_}
		}
	}
	return '';
}

sub registerPerlfuncs { my ($props,$funcstr)=@_;
	my($name)=$props=~/name=\"(.*?)\"/ois;
	$dbweb::perlFuncs{code}{$name}.= "\n".$funcstr if(length $name);
	$dbweb::perlFuncs{param}{$name}.=" ". $props   if(length $name);
	return '';
}
sub getPerlfuncCode { my ($perlfunc)=@_;
	return '' unless (length $perlfunc);
	my $r = *$perlfunc{CODE};
	return getAPICode(). "\n". "$perlfunc()" if (ref($r) eq 'CODE');

	my $params=	$dbweb::perlFuncs{param}{$perlfunc};
	my $code  =	$dbweb::perlFuncs{code}{$perlfunc};
	return '' unless(length $code);

	if($params=~/include=\"(.*?)\"/o )
	{	my $incl = LWP::Simple::get($dbweb::pathPrefix.$1);
		$code=$incl."\n".$code;
	}

	$code=getAPICode().$code;

	return $1 if($code=~/(.*)/os);
	return '';
}

sub nameOfDG{ my ($displayGroup)=@_;
	map {	return $_ if($dbweb::displayGroups->{$_} == $displayGroup)	} keys(%{$dbweb::displayGroups});
	return undef;
}
sub registerPerlmodule { my ($str)=@_;
	$str->import;
	DG::registerPerlmodule($str);
	return '';
}

sub selectedIDOfDisplayGroupName{ my ($displayGroupName)=@_;
	my $dg=$dbweb::displayGroups->{$displayGroupName};
	my $tdg;
	$tdg=$dbweb::displayGroups->{$dg->{bindToDG}} if(length $dg);
	return lookupDataForPathAndPK ( $dg->{bindToDG}.'.'.$dg->{bindToColumn}, selectedIDOfDisplayGroupName($dg->{bindToDG}))
		if(length $tdg && length $dg->{bindToColumn});

	return getRawDataForDG($dg)->[0]->[getIndexOfColumnInDG($dg->{primaryKey}, $dg)] if($dg && $dg->{DataInSession});

	return sessionData('selectedID_'.$displayGroupName);
}
# cascaded lookup, return first valid connection dictionary
sub connectionDictionaryForDG { my ($displayGroup)=@_;
	my $con;
	if(length $displayGroup->{connection})
	{	$con=$displayGroup->{connection}
	} elsif(length $displayGroup->{connectionEnv})
	{	$con=$main::ENV{$displayGroup->{connectionEnv}}
	} elsif(length $displayGroup->{connectionEnvAuto})
	{	$con=$main::ENV{$dbweb::handlerName.'_connectionstring_'.$dbweb::pathAddendum};
	} elsif(length $displayGroup->{connectionDG})
	{	$con=lookupDataForPathAndPK ( $displayGroup->{connectionDG}, selectedIDOfDisplayGroupName(nameOfDG($displayGroup)) );
	}
	if(length $con)
	{	my ($user,$password);
		my $dgName=nameOfDG($displayGroup);
		if(exists $displayGroup->{AuthSession})
		{	my $sessionDGName=$displayGroup->{AuthSession};
			my $vals=sessionData('session_'.$sessionDGName);
			if(length $vals)
			{	$user=$vals->{user};
				$password=$vals->{password};
			}
		}
		$user=$displayGroup->{user} if(exists $displayGroup->{user});
		$password=$displayGroup->{password} if(exists $displayGroup->{password});
		my $cdict={connection=>$con, user=>$user, password=>$password};
		$cdict->{encoding}=(length $displayGroup->{DBEncoding})? $displayGroup->{DBEncoding}:'iso-8859-1';	# latin1 is the default for backwards-compat
		return $cdict;
	}
	return connectionDictionaryForDG($dbweb::displayGroups->{$displayGroup->{bindToDG}})
		if(exists $displayGroup->{bindToDG});	# connectionDictionaryForDG: fallback to masterDG when undefined
	warn "cannot find database connection for DG:".nameOfDG($displayGroup);
	return undef;
}

sub getIndexOfColumnInDG { my ($row, $displayGroup)=@_;
	my ($i,$currName);
	my $columnNames=$displayGroup->{columns};
	for($i=0;$i <= $#{$columnNames}; $i++)
	{	return $i  if($columnNames->[$i] eq $row)
	};
	my $dgn=nameOfDG($displayGroup);
###	warn "unmatched rowname $row specified for $dgn!";
	return undef;
}

sub loginerror {
	setGlobal({'__dbloginerror__'=>1} );
	activateApplication($dbweb::loginname);
}

sub getDBHForDG { my ($displayGroup)=@_;
	my $tableName=$displayGroup->{table};
	if(length $tableName)
	{	my ($dbh,$dgn);
		my $connDict=connectionDictionaryForDG($displayGroup);
		return $dbweb::_dbhH{$connDict->{connection}} if(exists $dbweb::_dbhH{$connDict->{connection}});
		unless(length $dbh)
		{	return undef unless length   $connDict->{connection};
			unless ($dbh = DBI->connect ($connDict->{connection}, $connDict->{user}, $connDict->{password}, { RaiseError=>0 } ) )	# autocommit=>0
			{	loginerror();
				goto __exit__;
			}
			$dbh->{pg_enable_utf8}=1 if($connDict->{connection}=~/:pg:/oi && $connDict->{encoding}=~/utf-?8/oi);
			$dbweb::_dbhH{$connDict->{connection}}=$dbh;
			$dbweb::_dbhE{$dbh}={ encoding=> $connDict->{encoding}, dateformatter=> undef };	# DateTime::Format::DBI->new($dbh)
		}
		return $dbh;
	} return undef;
}

sub getUndoDGForDG { my ($displayGroup)=@_;
	return $dbweb::displayGroups->{$displayGroup->{undoDG}} if exists $displayGroup->{undoDG};
	return getUndoDGForDG($dbweb::displayGroups->{$displayGroup->{bindToDG}}) if exists $displayGroup->{bindToDG};
	return undef;
}

sub disconnectAllDBHs {
	for  ( keys %dbweb::_dbhH )
	{	my $dbh=$dbweb::_dbhH{$_};
		$dbh->commit() unless $dbh->{AutoCommit};
		$dbh->disconnect();
	}
}

sub getRawDataForDG { my ($displayGroup,$whereclauseDict, $opts)=@_;
	my ($additionalWhere, $sortArr)=($opts->{additionalWhere}, $opts->{sort});
	my $columnNames=$displayGroup->{columns};
	my $tableName=$displayGroup->{table};
	if(length $tableName || $displayGroup->{data} || $displayGroup->{cache})
	{	my $dbh;
		$dbh=getDBHForDG($displayGroup) if(length $tableName);
		my $combinedWhere={};
		$combinedWhere->{$_}=$whereclauseDict->{$_} for ( keys %{$whereclauseDict} );
		$combinedWhere->{$_}=$additionalWhere->{$_} for ( keys %{$additionalWhere} );
		if($displayGroup->{cache} || $displayGroup->{data})
		{	return getColumnsFromCacheForDGNAndDict($dbh, nameOfDG($displayGroup),$combinedWhere,$sortArr, $opts);
		} else
		{	$opts->{types}=$displayGroup->{types};
			return getColumnsOfTableForDict ( $dbh,$columnNames,$tableName,$combinedWhere, $opts );
		}
	} elsif(length $displayGroup->{DataInSession})
	{	my $dgName=nameOfDG($displayGroup);
		my $udict =sessionData('session_'.$dgName);
		return [] unless(length $udict);
		my @currRow=map { $udict->{$_} } (@{$columnNames});
		return [\@currRow];
	}
}
sub getDataForDGN { my ($displayGroupName,$optHash)=@_;
	my $displayGroup=$dbweb::displayGroups->{$displayGroupName};
	my $additionalWhere=$optHash->{'whereClause'};
	my $sortArr=$optHash->{'sort'};
	my $boundToDG=$displayGroup->{bindToDG};

	if($optHash->{'filter'})
	{	my $filterH=whereClauseForFilterOfDGName($optHash->{'filter'}, $displayGroupName);
		$additionalWhere->{$_}=$filterH->{$_} for keys %{$filterH};
	}

	# get data from database
	my $whereclauseDict={};
	if(length $boundToDG)				# construct constraining dictionary from contents of binding dg
	{	my $PKboundToDG=$optHash->{pk}? $optHash->{pk}: selectedIDOfDisplayGroupName($boundToDG);
		my $boundFromColumn=$displayGroup->{bindFromColumn};
		if (length $boundFromColumn)		# master detail configuration
		{	$whereclauseDict->{$boundFromColumn}= ( (exists $displayGroup->{targetColumn})?
				lookupDataForPathAndPK($boundToDG.'.'.$displayGroup->{targetColumn},$PKboundToDG): $PKboundToDG);
			return undef unless length $whereclauseDict->{$boundFromColumn};
		} elsif(exists $displayGroup->{bindFromColumns} )
		{	for(@{$displayGroup->{bindFromColumns}}) 
			{	my $val=lookupDataForPathAndPK($boundToDG.'.'.$_, $PKboundToDG);
					$whereclauseDict->{$_}=$val if length $val;
			}

		} else	# use boundTo DGs for constructing whereclause
		{	$whereclauseDict=sessionData('where_'.$boundToDG) unless(exists $dbweb::displayGroups->{$boundToDG});			# unboundForm used for searching
		}
	} my $opts=$optHash;
	$opts->{additionalWhere}=$additionalWhere;
	$opts->{sort}=$sortArr? $sortArr : ($displayGroup->{autoSort}? $displayGroup->{sortColumns}->{$displayGroup->{autoSort}}:undef );
	return getRawDataForDG($displayGroup,$whereclauseDict, $opts) ;
}

sub whereClauseForFilterArray { my ($arr)=@_;
	my $ret={};
	my $i;
	for( @{$arr} )
	{	if($_->{op} eq 'eq')		{ $ret->{$_->{col}}=$_->{val} }
		elsif($_->{op} eq 'eqnull')	{ $ret->{$_->{col}}=\$dbweb::globalNullObject }
		elsif($_->{op} eq 'nenull') { $ret->{$_->{col}}={op=>'ne', val=>\$dbweb::globalNullObject} }
		elsif($_->{op} eq 'ne') { $ret->{$_->{col}}={op=>'<>', val=>$_->{val} } }
		elsif($_->{op} eq 'literal') {$ret->{$_->{col}}=$_}
		else
		{	unless(exists $ret->{$_->{col}})
			{	$ret->{$_->{col}}=$_;
			} else
			{	$ret->{$_->{col}.'__alias__'.$i++}=$_;
			}
		}
	} return $ret;
}

# cascaded search for appropriate dg-filter
sub whereClauseForFilterOfDGName { my ($filterName,$displayGroupName)=@_;
	my $dg=$dbweb::displayGroups->{$displayGroupName};
	unless(exists $dg->{filters})
	{	return whereClauseForFilterOfDGName($filterName,$dg->{bindToDG}) if(exists $dg->{bindToDG});
	} else
	{	my $filter=$dg->{filters}->{$filterName};
		$filter=[$filter] if (ref($filter) eq 'HASH');			#isKindOf:dict-> wrap with array
		return whereClauseForFilterArray($filter);
	}
	return undef;
}

sub lookupDataForPathAndPK { my ($path,$val)=@_;
	my ( $displayGroupName,$fieldName);
		($displayGroupName,$fieldName)=($1,$2) if($path=~/(.*?)\.(.*)/o);
	return undef unless exists $dbweb::displayGroups->{$displayGroupName};
	return undef if (!(length $val) && (!(length $dbweb::displayGroups->{$displayGroupName}->{DataInSession})));
	my $data=getRawDataForDG($dbweb::displayGroups->{$displayGroupName},{$dbweb::displayGroups->{$displayGroupName}->{primaryKey}=>$val});
	return $data->[0]->[getIndexOfColumnInDG($fieldName,$dbweb::displayGroups->{$displayGroupName})];
}


sub formatDataField { my ($displayGroupName,$fieldName,$val,$formelem,$paramHashR)=@_;
	return $1 if($formelem=~/lookup=\"const:(.*?)\"/ois);
	$val=lookupDataForPathAndPK($1,$val) if($formelem=~/lookup=\"(.*?)\"/ois );

	if($formelem=~/format:date=\"(.*?)\"/ois)
	{	my $format=$1;
		$paramHashR->{'format'}->{$fieldName}='date:'.$format;
		$paramHashR->{'nullify'}->{$fieldName}=1;
# <!> replace by DateTime and remove POSIX module
		$val=strftime($format,$6,$5,$4,$3,$2-1,$1-1900)			 if ($val=~ /([0-9]+)-([0-9]+)-([0-9]+) ([0-9]+):([0-9]+):([0-9]+)/o);
		$val=strftime($format,undef,undef,undef,$3,$2-1,$1-1900) if ($val=~/^([0-9]+)-([0-9]+)-([0-9]+)$/o);
	} elsif($formelem=~/format:number/ois)
	{	$paramHashR->{'nullify'}->{$fieldName}=1;
	}
	return $val;
}
sub expandFormfield { my ($displayGroupName,$formName,$fieldName,$formelem,$primaryKey,$forInsert,$paramHashR,$datarow, $formclass)=@_;
	($displayGroupName,$fieldName)=($1,$2) if($fieldName=~/(.*?)\.(.*)/o);
	my $qnameStr=join('_', ($displayGroupName,$fieldName) );
	my $dg=$dbweb::displayGroups->{$displayGroupName};
	my $class;
	my $wantID;
	my $idname =$qnameStr.'_'.$dbweb::_uniqueID++;

	$idname=$1 if($formelem=~/id=\"([^\"]+)\"/ois);

	if($formelem=~s/class=\"([^\"]+)\"//ois)
	{	$class=$1;
	}
	my ($val,$val2);
	unless(length $dg)		# unbound?
	{	$val=decodeCGI($qnameStr);						# then data might be in $dbweb::cgi
	} else
	{	if(length $primaryKey || defined $dg && $dg->{DataInSession})
		{	$datarow=getRawDataForDG($dg,{$dg->{primaryKey}=>$primaryKey})->[0] unless length $datarow;
		}
		$val=$datarow->[getIndexOfColumnInDG($fieldName,$dg)] unless($forInsert);
	} $val2=formatDataField($displayGroupName,$fieldName,$val,$formelem,$paramHashR);

	unless($forInsert)
	{	$paramHashR->{'snapshot'}->{$fieldName}=$val2 ;	# formatted schnappschuss im datenbank encoding
		$paramHashR->{'snapshot2'}->{$fieldName}=$val;	# schnappschuss unformatted
	}
	$val =encode_entities($val);
	$val2=encode_entities($val2);										# switch to web encoding

	my ($prefix,$postfix,$postfix2);
	my  $prefix2='<input ';
	$prefix='<label for="'.$qnameStr.'">'.$1."</label>\n" if($formelem=~/label=\"([^\"]+)\"/ois);

	$postfix.=$1 if($formelem=~/(style=\"[^\"]+\")/ois);
	$postfix.=$1 if($formelem=~/(autocomplete=[\"']*off[\"']*)/ois);

	$formelem=~s/edittype=boolean/$val? 'type=checkbox checked' : 'type=checkbox'/egs;
	if($formelem=~/\btype=checkbox\b/oi)			# make checkboxes directly responsive
	{	$paramHashR->{'format'}->{$fieldName}='bool';
		$val=$val2=$val? 1:0;
	}
	if($formelem=~s/\beditmode=inplace\b//oi)
	{	$wantID=1;
		$dbweb::JSConfigs{inplace}->{$idname}->{field}=$fieldName;
		$dbweb::ajaxReturn{values}{$idname}=((length $val2)? $val2:$val);
		$class.=($class?' ':'').'DBW_inplace';
	}
	if($formelem=~s/\bedittype=(popup|combo|text)\b/type=text/oi)
	{	my $isText=($1 eq 'text');
		my $isPop=($1 eq 'popup');
		my ($whereClause,$typeahead, $pk, $filterName,$lDGN,$lFieldName,$lFilterName);
		my ($order) = ($formelem =~ m{order\s*=\s*(\"(.*?)\"|[a-z0-9]*)}ois);
		my  $sort = $dg->{sortColumns}{$order};

		if($formelem=~/(lookup|typeahead)=\"(.*?)\"/ois)
		{	my $bindTo=$2; $typeahead=1;
			($lDGN,$lFieldName)=($1,$2) if($bindTo=~/(.*?)\.(.*)/o);	# changes focus to lookup context
			$pk=$datarow->[getIndexOfColumnInDG($1,$dg)] if($lFieldName =~s/\@(.*)//o);
			$sort = $dbweb::displayGroups->{$lDGN}{sortColumns}{$order};
			if($lFieldName =~/(.*?)\.(.*)/o)	#is there a filter appended?
			{	($lFieldName,$lFilterName)=($2,$1);
				$whereClause = whereClauseForFilterOfDGName($lFilterName,$lDGN) if (length $lFilterName);
			} else { $whereClause ={} }
		}
		my ($valIndex,$pkIndex,$data);

		if(!$isText  || $typeahead || $isPop )
		{	my $dg2=$dbweb::displayGroups->{$lDGN};
			$valIndex=getIndexOfColumnInDG($lFieldName,$dg2);
			$pkIndex= getIndexOfColumnInDG($dg2->{primaryKey},$dg2);
			$data=getDataForDGN($lDGN, {whereClause=>$whereClause, pk=>$pk, sort => $sort} ) if ($isPop) ;
		}
		if($isPop)
		{	my $allowsNils=1;
			my $sel=0;
			$allowsNils=0 if($formelem=~/format:notNull=(\"*)YES(\"*)/oi);

			unshift(@{$data},[]) if ( ( $#{$data}==-1 || scalar(@{$data->[0]} ) ) && ( $forInsert || $allowsNils) );
			my $options= join("\n<option value=",
				map { $_->[$pkIndex].' '.(($_->[$pkIndex] eq $val)? ($sel=1,'selected'):'').'> '.$_->[$valIndex] } (@{$data}) );
			$options=~s/^ selected> /\"\" selected>/osg;
			$paramHashR->{'nullify'}-> {$fieldName}=1 if(!$forInsert && $allowsNils);
			$paramHashR->{'snapshot'}->{$fieldName}=$val;	# overwrite $val2
			$postfix .=' id="'.$idname.'"' if($wantID);
			$postfix.=' class="'.$class.'"' if($class);
			return $prefix.'<select name="'.$qnameStr.'" '.$postfix.">\n<option value=".$options."\n</select>";

		} elsif( !$isText  || $typeahead )	# combo
		{	$wantID=1;
			$dbweb::JSConfigs{autocomplete}->{$idname}->{dg}=	$lDGN;
			$dbweb::JSConfigs{autocomplete}->{$idname}->{field}=	$lFieldName;
			$dbweb::JSConfigs{autocomplete}->{$idname}->{filter}=	$lFilterName;
			$dbweb::JSConfigs{autocomplete}->{$idname}->{pk}=	$pk;
			$dbweb::JSConfigs{autocomplete}->{$idname}->{nopulldown}=($formelem=~s/\bpulldown=[\"']*off[\"']*//oi)? 1:0;
			$class.=($class?' ':'').'combobox';

			$val=$val2='' if($forInsert);
			unless($isText)			# only combo
			{	$paramHashR->{'combo'}->{$fieldName}->{dg}=$lDGN;
				$paramHashR->{'combo'}->{$fieldName}->{field}=$lFieldName;
				$paramHashR->{'combo'}->{$fieldName}->{filter}=$lFilterName;
				$paramHashR->{'nullify'}->{$fieldName}=1;
			}
		}
	}
	elsif($formelem=~s/\bedittype=upload\b/type=file/ogi)
	{	$$formclass.='DBW_noajax' if $formclass;
		$postfix.=' class="'.$class.'"' if($class);
		return $prefix.$prefix2.$formelem.' name="'.$qnameStr.'"'.$postfix.'>';
	}
	elsif($formelem=~s/\bedittype=img//ogi)
	{	my ($confirm,$fn,$fm,$pk);
		delete $paramHashR->{'snapshot'}->{$fieldName};
		$confirm=$1 if($formelem=~s/confirm=\"(.*?)\"//ogsi);
		unless($forInsert)
		{	my $d={};
			$d->{fn}=$1 if($formelem=~s/perl=\"(.*?)\"//ogsi);
			$forInsert=storeFormSupportInfo($displayGroupName, $formName.$d->{fn}, $d ,$primaryKey, 'img') ;
		}
		$formelem.=' class="'.$class.'"' if($class);
		return $prefix.'<img '.$formelem.' onClick="javascript:dbweb.submitAction(\''.$confirm.'\',\''.$forInsert.'\')">';
	} elsif($formelem=~s/edittype=textarea/<textarea /ogi)
	{	$prefix2=''; $postfix2.=((length $val2)? $val2:$val).'</textarea>';$val=$val2='';
	} elsif($formelem=~s/edittype=plain//ogi)
	{	delete $paramHashR->{$_}->{$fieldName} for qw/snapshot snapshot2/;
		return (length $val2)? $val2:$val;
	}


	if($formelem=~/\bformat:tooltip=\"([^\"]*)\"/os)
	{	my $ttText=$1;
		$postfix.=' title="'.$ttText.'"'; 
	}

	if($wantID && !($formelem=~/id=\"/oi))
	{	$postfix .=' id="'.$idname.'"';
	} else
	{	$dbweb::_uniqueID--;
	}

	$formelem=~s/\bedittype=/type=/og;
	$formelem=~s/\b(format|lookup)[^=]*=\"[^\"]*\"//ogs;
	$postfix.=' class="'.$class.'"' if($class);
	return $prefix.$prefix2.$formelem.' name="'.$qnameStr.'" value="'.((length $val2)? $val2:$val).'" '.$postfix.'>'.$postfix2;
}

sub hiddenInputParameters { my ($paramdict)=@_;
 	return join(' ', map { '<input type=hidden name="'.$_.'" value="'.$paramdict->{$_}.'">' } keys(%{$paramdict}));
}

sub uniqueFormNameForDGName { my  ($displayGroupName)=@_;
	$dbweb::_globalDGIdentifier{F}{$displayGroupName}++;
	my $ret=$displayGroupName.'_'.$dbweb::_globalDGIdentifier{F}{$displayGroupName};
	$ret =~s/\./_/ogs;
	return $ret;
}
sub uniqueTabNameForDGName { my   ($displayGroupName)=@_;
	$dbweb::_globalDGIdentifier{T}{$displayGroupName}++;
	my $ret='ajaxtab_'.$displayGroupName.$dbweb::_globalDGIdentifier{T}{$displayGroupName};
	$ret =~s/\./_/ogs;
	return $ret;
}
sub storeFormSupportInfo{ my ($displayGroupName, $formName,$paramHashR, $primaryKey, $presel)=@_;
	$paramHashR->{dg}= $displayGroupName;
	$paramHashR->{pk}= $primaryKey if length $primaryKey;
	my $fi=$presel.$formName.$primaryKey;
	sessionData('forminfo_'.$fi, $paramHashR);
	return $fi;
}
sub isDGNEmpty { my ($displayGroupName)=@_;
	return 	defined $dbweb::displayGroups->{$displayGroupName} && defined $dbweb::displayGroups->{$displayGroupName}->{bindToDG} && (!length selectedIDOfDisplayGroupName($displayGroupName)  ) ;

}

sub handleForm { my ($displayGroupName, $formparams, $block, $primaryKey, $datarow)=@_;
	my ($reta, $retb, $style, $trail, $plain);
	$retb='<div class="dataform_caption">'.$1.'</div>' if($formparams=~s/label=\"(.*?)\"//ogs);
	$style=$1  if($formparams=~s/(style=[\"'].*?[\"'])//ogs);
	$style.=" $1" if($formparams=~s/(id=[\"'].*?[\"'])//ogs);
	$plain=1 if($formparams=~s/(plain=[\"']{0,1}.*?[\"']{0,1})//ogs);

	my $formName=uniqueFormNameForDGName($displayGroupName);
	unless(length $primaryKey) {$reta='<fieldset>'.$reta; $trail.='</fieldset>'}	# nicht die forms in tabellen als fieldset markieren

	return '' if( !(length $primaryKey) && isDGNEmpty($displayGroupName));
	$primaryKey= selectedIDOfDisplayGroupName($displayGroupName) unless length $primaryKey;
	my $dg=$dbweb::displayGroups->{$displayGroupName};

	$datarow=getRawDataForDG($dg,{$dg->{primaryKey} => $primaryKey})->[0] unless length $datarow;

	$block=~s/<cond ([^>]+?)>(.*?)<\/cond>/handleCond($displayGroupName,$1,$2, $datarow)/oeigs if($block=~/<cond/o);
	my $paramHashR={};
	my $addClass='';
	$block=~s/<var:([^>]+?)\b([^>]*edittype=[^>]*)>/expandFormfield($displayGroupName,$formName,$1,$2,$primaryKey, undef, $paramHashR,$datarow,\$addClass)/oegs;
	$block =~s/<button:(.+?)\b(.*?)>/handleButton($1,$2,$primaryKey,$displayGroupName)/oeigs;
	$paramHashR->{'u'}='y';
	$paramHashR->{'fn'}=$1  if($formparams=~/perl=\"(.*?)\"/o || $block=~/perl=\"(.*?)\"/o);
	$paramHashR->{'fna'}=$1 if($formparams=~/action=\"(.*?)\"/o);

	$style.=' class="'.$addClass.'" ' if length $addClass;
	my $params=hiddenInputParameters({ 'forminfo'=> storeFormSupportInfo($displayGroupName,$formName,$paramHashR,$primaryKey) });
	my $ret= $retb.'<form action='.$dbweb::URI.' name="'.$formName.'" method=POST enctype="multipart/form-data" '.$style.'>'.$reta;

	return $block if $plain;
	return $ret.$block."\n".$params.$trail.'</form>';
}

sub handleButton { my ($name,$block,$pk, $dgn)=@_;
	if($block=~/perl=\"(.*?)\"/o)
	{	my $d={fn=>$1, buttonname=>$name};
		my $confirm=($block=~s/confirm=\"(.*?)\"//ogsi)? $1:'';
		my $fi=storeFormSupportInfo($dgn, $dgn.$name.$d->{fn}, $d, $pk, 'button');
		my $progress=($block=~/progress=[\"]{0,1}([0-9]+)/io)? $1:'0';
		my $noajax=($block=~/ajax=[\"]{0,1}(.*?)(\s|>|\")/io)? $1:'';
		my $ajax=($noajax =~ /true|yes|on/io)?1:0;
		$noajax=$ajax? 'false':'true';
		return 'javascript:dbweb.submitAction(null,\''.$fi."',".$noajax.')' if $name eq '_Javascript_';
		return 'dbweb.submitAction(null,\''.$fi."',".$noajax.')' if $name eq '_JavascriptImg_';
		$name=~s/_/ /og;
		return '<input type="button" value="'.$name.'" onClick="dbweb.submitAction(\''.$confirm.'\',\''.$fi."',".$noajax.','. $progress.',this)">';
	}
	return '<input type="submit" value="'.$name.'">';
}

sub handleCounts { my ($displayGroupName, $field)=@_;
	my ($filter,$whereClause);
	$filter=$1 if($field=~/^\.(.+?)\b/os);
	$whereClause= whereClauseForFilterOfDGName($filter, $displayGroupName) if (length $filter);
	my $data=getDataForDGN($displayGroupName,{whereClause=>$whereClause, countOnly=>1});
	return $data->[0]->[0];
}

sub boostSelectionForDGN { my ($dgn, $opts)=@_;
	return if length sessionData('selectedID_'. $dgn );
	my $dg= $dbweb::displayGroups->{$dgn};
	boostSelectionForDGN( $dg->{bindToDG}, $opts )
		if(defined $dg->{bindToDG} && defined $displayGroups->{$dg->{bindToDG}});

	my $data=getDataForDGN($dgn, {%{$opts}});
	if(length $data && $#{$data} >=0)
	{	sessionData('selectedID_'.$dgn, $data->[0]->[getIndexOfColumnInDG($dg->{primaryKey}, $dg)]);
	}
}

sub handleCond { my ($displayGroupName, $field, $block, $datarow)=@_;
	($displayGroupName, $field)=($1,$2) if $displayGroupName =~ /(^[^\b]+?)\b(.+)/os;
	$block=~ s/<condDG:([^>]+?)\b([^>]*?)>(.*?)<\/condDG:\1>/handleCond($1, $2, $3)/oeigs;		# for nested conds. dont pass datarow.
	my($var,$cond)=$field=~/var:([^=]+)=(nenull|null|true|false|\"const:[^\"]*\"|\"..:const:[^\"]+\")/ois;
	my ($filter, $whereClause);

	$filter=$1 if($field=~/^\.(.+?)\b/os);
	$whereClause= whereClauseForFilterOfDGName($filter, $displayGroupName) if length $filter;

	unless(length $var)
	{	if($field=~/selection=(true|false|visible|invisible)/oigs)
		{	my $dst=0;
			my $bool=$1;
			if($bool eq 'visible' || $bool eq 'invisible')
			{	my $sid=selectedIDOfDisplayGroupName($displayGroupName);
			#	return '' unless length $sid;
				return ( ($bool eq 'visible') ? '':$block) unless length $sid;
				$whereClause->{ $dbweb::displayGroups->{$displayGroupName}->{primaryKey} }= $sid;
				my $data=getDataForDGN($displayGroupName,{whereClause=>$whereClause, countOnly=>1});
				if($bool eq 'visible')
				{	return $block if $data->[0]->[0];
				} else
				{	return $block unless $data->[0]->[0];
				}
				return '';
			} else
			{	$dst=1 if($bool=~/true/oigs);
				return $block if(( (length selectedIDOfDisplayGroupName($displayGroupName) )?1:0 ) == $dst);
				return '';
			}
		} elsif($field=~/count=\"gt:const:([0-9]+)\"/ois)
		{	my $const=$1;
			my $data=getDataForDGN($displayGroupName,{whereClause=>$whereClause});
			my $count = $data? $#{$data}: -1; 
			return $block if($count > $const-1);
			return '';
		}
	}

	my $val=(length $datarow)? $datarow->[getIndexOfColumnInDG($var,$dbweb::displayGroups->{$displayGroupName})]:
				( boostSelectionForDGN($displayGroupName,{whereClause=>$whereClause}), lookupDataForPathAndPK($displayGroupName.'.'.$var, selectedIDOfDisplayGroupName($displayGroupName) ) );
	#			lookupDataForPathAndPK($displayGroupName.'.'.$var, selectedIDOfDisplayGroupName($displayGroupName) );
	if ($cond=~/gt:const:([^\"]+)/ois)
	{	return $block if($val gt $1);
	} elsif ($cond=~/lt:const:([^\"]+)/ois)
	{	return $block if($val lt $1);
	} elsif( $cond=~/(eq:){0,1}const:([^\"]+)/ois)
	{	return $block if($val eq $2);
	} elsif($cond=~/nenull/ois)
	{	return $block if length $val;
	} elsif($cond=~/null/ois)
	{	return $block unless length $val;
	}
	else
	{	my $dst=0;
		$dst=1 if($cond=~/true/ois);
		$val=0 unless length $val;
		return $block if(($val?1:0) == $dst);
	}
	return '';
}

sub handleAction { my ($block)=@_;
	my ($displayGroupName)=$block=~/^(.+?)\s/o;
	$block=~s/^(.+?)\s//o;
	my $formName= uniqueFormNameForDGName($displayGroupName);
	my ($action,$cgiparams,$perlform,$paramHashR,$fieldname);

	my $ret='<form action='.$dbweb::URI.' name="'.$formName.'" method=post>'."\n";
	if($displayGroupName=~/(.*?)\.(.*)/o )
	{	my $filterName;
		($displayGroupName,$filterName)=($1,$2);
		if (length $filterName)
		{	my $additionalHash= whereClauseForFilterOfDGName($filterName,$displayGroupName);
			$paramHashR->{'addColsFromFilter'}=$filterName;
		}
	}
	if($block=~s/perform:(insert|delete|perl)=\"(.*?)\"//oi)
	{	$action=$1;	my $param=$2;
		if ($action eq 'insert')
		{	$fieldname=$1 if ($param =~/^var:(.*)/o);
		} elsif($action eq 'delete')
		{	$action='deleteall' if ($param eq 'all');
		} elsif($action eq 'perl')
		{	$perlform=$param;
		}
	} 
	$paramHashR->{'fn'}=$perlform if $perlform;
	$paramHashR->{'fn'}=$1 if($block=~/perl=\"(.*?)\"/o);
	$paramHashR->{'a'}=$action;
	my $fi=storeFormSupportInfo($displayGroupName, $formName, $paramHashR);
	$block=expandFormfield($displayGroupName,$formName,$fieldname,$block,undef, $fi, $paramHashR) if(length $action);
	$cgiparams.=hiddenInputParameters({ forminfo=> $fi } );
	return $ret.$block."\n".$cgiparams.'</form>';
}

sub linkedDataFormfield { my ($displayGroupName,$fieldName,$felem,$val,$pk,$classname)=@_;
	my $val2=formatDataField ($displayGroupName,$fieldName,$val,$felem);
	if($felem =~/format:link=\"(.+?)\.([^"]*)\"/ogi)
	{	my ($app,$tdg)=($1,$2);
		$val2='' unless $val;
		return '<a href="javascript:dbweb.L(\''.$app.'\',\''.$val.'\',\''.$tdg.'\')" style="text-decoration:underline;">'.$val2.'</a>';
	} else
	{	return '<a onclick="dbweb.J(event)" class="FLD_'.$fieldName.($classname? " $classname":'').'"'.$felem.'>'.$val2.'</a>';
	}
}

sub dataEssentalsTableHeader { my ($displayGroupName, $opts)=@_;
	my ($data, $filterName);
	($displayGroupName, $filterName)=($1,$2) if($displayGroupName=~/(.*?)\.(.*)/o);

	$opts->{filter}= $filterName if (length $filterName);
	$opts->{limit}= $opts->{length};
	if(my $overrideDefaultSorting=sessionData('defaultsortfilter_'.$displayGroupName))
	{	$overrideDefaultSorting.='_rev' if (sessionData('defaultsortupdown_'.$displayGroupName) eq 'up');
		my $dg=$dbweb::displayGroups->{$displayGroupName};
		$opts->{sort}=$dg->{sortColumns}->{$overrideDefaultSorting}
			if(exists $dg->{sortColumns} && exists $dg->{sortColumns}->{$overrideDefaultSorting});
	}
	my	$data=getDataForDGN($displayGroupName, $opts);
	return ($data, $displayGroupName, $filterName);
}


sub handleTable { my ($rawDisplayGroupName, $block)=@_;
	my $ret;
	my $rows=   ($rawDisplayGroupName=~s/\s+rows=\"([^\"]+)\"//ogs)? $1: undef;
	my ($data, $displayGroupName, $filterName)= dataEssentalsTableHeader($rawDisplayGroupName, {countOnly=>1} );
	my $realrows=$data->[0]->[0];

	my ($pref, $foreachblockraw) = $block =~/^(.*?)<foreach>(.*?)<\/foreach>/os;
	return '' unless length $foreachblockraw;
	my ($pref1,$head, $pref)= $pref=~/(.*?)<head>(.*?)<\/head>(.*)/os;
	my @colsS=split /<\/col>/o,$head; pop @colsS;
	my @cols;
	my $totalWidth;

	foreach my $ccol (@colsS)
	{	my ($width,$unit, $name)= $ccol=~/<col:([0-9]+)(.*?)>(.*)/os;
		$totalWidth+= $width;
		push @cols, {name=>$name, width=>$width, unit=>$unit};
	}
	my $idname = uniqueTabNameForDGName($displayGroupName);
	my $head;
	if(scalar @cols)
	{	my $sortable= sessionData('defaultsortfilter_'.$displayGroupName);
		my $up_down=  sessionData('defaultsortupdown_'.$displayGroupName);

		$head='<table id="'. $idname.'_header" class="datatable" style="width:'.$totalWidth.'px; table-layout: fixed;">'. $pref1.'<tr>';
		$head.='<th onclick="dbweb.sortable('."'$displayGroupName','$_->{name}'".')" style="width:'.$_->{width}.$_->{unit}.';"'.($_->{name} =~ /\b\Q$sortable\E\b/? ('class="dbweb_sort_'.$up_down.'";') :'').'>'.$_->{name}.'</th>' for (@cols);
		$head.='</tr></table>';
		$ret.='<table id="'. $idname.'" class="datatable" style="width:'.$totalWidth.'px;">';
	}

	my @rowsarr= split /<\/cell>/o, $foreachblockraw; pop @rowsarr;
	my $i;
	my $foreachblock='<tr>';
	my $i=0;
	for  (@rowsarr)
	{	$_=~s/<cell>//ogs;
		my $w=$cols[$i++]->{width};
		$foreachblock.='<td><div style="height:1.3em;width:'.$w.'px;overflow:hidden">'.$_.'</div></td>'
	};
	$foreachblock.='</tr>';

	sessionData('ajaxtab_'.$idname, $foreachblock);
	my $offset=sessionData('row_'.$idname);
	$offset=(length $offset)? $offset:0;
	$offset=($offset>($realrows-$rows))? ($realrows-$rows):$offset;
	$offset=0 if($offset<0);
	if($realrows>$rows)
	{	$dbweb::JSConfigs{tables}->{$idname}->{offset}=$offset;
		$dbweb::JSConfigs{tables}->{$idname}->{dg}=$displayGroupName;
		$dbweb::JSConfigs{tables}->{$idname}->{totalrows}= $realrows;
		$dbweb::JSConfigs{tables}->{$idname}->{rows}=$rows;
		$dbweb::JSConfigs{tables}->{$idname}->{filter}=  $filterName;
	} else
	{	$offset=0;
	}

	if(0)
	{	handleForeach($rawDisplayGroupName);	# handle selection
		return $head.$ret. $foreachblock x $rows.'</table>';
	} else
	{	#  prevent flickering  but double fetches some rows on the con side...
		my $params={ offset=>$offset, length=>$rows };
		$params->{filter}=$filterName if($filterName);
		$pref=handleForeach($rawDisplayGroupName, $foreachblock, $params);
		return $head.$ret.$pref.'</table>';
	}
}

sub handleForeach { my ($displayGroupName, $foreachblock, $ajaxParams)=@_;
	my $perlfunc=($displayGroupName=~s/\s+perl=\"([^\"]+)\"//ogs)?$1: undef;
	my $classnameData=($displayGroupName=~s/\s+classnameVar=\"([^\"]+)\"//ogs)?$1: undef;
	my $reorder=($displayGroupName =~s/\s+reorderVar=\"([^\"]+)\"//ogs)?$1: undef;
	my $plain=($displayGroupName=~s/\s+plain=\"*yes\"*//oigs)?1:0;
	my $prefixWithID=($displayGroupName=~s/\s+prefixWithId=\"([^\"]+)\"//ogs)?$1:0;
	my ($ret, $data);

	($data, $displayGroupName)= dataEssentalsTableHeader($displayGroupName, $ajaxParams);

	my $dg=$dbweb::displayGroups->{$displayGroupName};
	my $columnIndexOfPK=getIndexOfColumnInDG($dg->{primaryKey},$dg);

	my $distinct=$dg->{distinct};
	my $columnIndexOfDistinct=(length $distinct)?	getIndexOfColumnInDG($distinct, $dg) : -1;
	my $columnIndexOfClass=(length $classnameData)? getIndexOfColumnInDG($classnameData, $dg) : -1;

	my 	$selectedID=selectedIDOfDisplayGroupName($displayGroupName);
	sessionData('selectedID_'. $displayGroupName, $selectedID=$data->[0]->[$columnIndexOfPK]) unless length $selectedID; 	# select first by default

	return ''	unless scalar @{$data->[0]};		# dg empty
	return '' if($foreachblock=~/^\s*$/ogs);		# empty block

	my $code;
	$code=getPerlfuncCode($perlfunc) if(length $perlfunc);
	my $distincts={};

	my $classname='DG_'.$displayGroupName;

	foreach my $row (@{$data})
	{	next if(($columnIndexOfDistinct>=0) && (exists $distincts->{$row->[$columnIndexOfDistinct]}));
		$distincts->{$row->[$columnIndexOfDistinct]}='' if ($columnIndexOfDistinct>=0);

		my $currblock=$foreachblock;
		my $pk=$row->[$columnIndexOfPK];
		$currblock=~s/(<t[rd])[^>]*?>/$1 class="$classname PK_$pk">/ois;	#<!> predefined classes on tr currently unsupported
		if($plain)
		{	$currblock=~s/(<var:(.+?)\b([^>]*)>)/$row->[getIndexOfColumnInDG($2,$dg)]/oeigs;
		} else
		{	$currblock=~s/<cond ([^>]+?)>(.*?)<\/cond>/handleCond($displayGroupName,$1,$2, $row)/oeigs if($currblock =~/<cond/o);
			$currblock=~s/(<var:([^>]+?)edittype=([^>]+?)>)/handleForm($displayGroupName,'', $1, $pk,$row)/oeigs if($currblock=~/edittype=/o);
			$currblock=~s/(<var:(.+?)\b([^>]*)>)/linkedDataFormfield($displayGroupName,$2,$3,$row->[getIndexOfColumnInDG($2,$dg)],$pk,
													($pk eq $selectedID)? 'selectedRow':'')/oeigs;
			$currblock=~s/class=\"([^\"]*)\"/class=\"class$classnameData$row->[$columnIndexOfClass] $1\"/ogs if($classnameData);
			$currblock=~s/class=\"\"//ogs;
			$currblock=~s/(class=\"[^\s\"]+)\s+\"/$1\"/ogs;
		}
		eval($code) if($code);
###warn $currblock;
		$ret.=$currblock;
	}
	$ret=~s/\b(format|lookup)[^=\w]*?=\".*?\"//ogs;
	if($prefixWithID)
	{	my $idname=uniqueTabNameForDGName($displayGroupName);
		$prefixWithID.="'$idname'>";
		$ret="$prefixWithID $ret";
		$dbweb::JSConfigs{sortable}->{$idname}= $reorder if($reorder);
	}
	return $ret;
}

sub nullifySessionPrefix { my ($prefix,$select)=@_;
 	map { delete $dbweb::session{$_} if(/^$prefix.*?$select/)} keys(%dbweb::session);
}

sub displayGroupDependsOnSelectionOfDGN { my ($otherDGName,$displayGroupName)=@_;
	my $dg=$dbweb::displayGroups->{$otherDGName};

	if(defined $dg && defined $dg->{bindToDG})
	{	return 1 if($dg->{bindToDG} eq $displayGroupName);
		return displayGroupDependsOnSelectionOfDGN($dg->{bindToDG},$displayGroupName);
	}
	return 0;
}

sub compileContextMenus {
	my $ret={};
	sub checkCondition { my  ($cond)=@_;
		my ($lval,$op,$rval)= $cond=~/^([^\s]+)\s+([^\s]+)\s+(.+)$/o;
		my ($displayGroupName,$fieldName)=$lval=~/(.*?)\.(.*)/o;
		my	$data=dbweb::lookupDataForPathAndPK($lval, dbweb::selectedIDOfDisplayGroupName($displayGroupName) ) ;
		eval($data.' '.$op.' '.$rval);
	}
	foreach my $dgn (keys %$dbweb::displayGroups)
	{	next unless exists $dbweb::displayGroups->{$dgn}->{contextmenu};
		my $cm=$dbweb::displayGroups->{$dgn}->{contextmenu};
		my @arr=grep { length $_->{name} || length $_->{separator} }
		map
		{	my $i=$_;
			$i->{name}="" if((exists $i->{condition}) && !checkCondition($i->{condition}) );
			for (qw/name className action/)
			{	$i->{$_}="'$i->{$_}'" if exists $i->{$_};
			}
			$i->{action}="''" unless exists $i->{action};
			$i->{javascript}.="dbweb.addHiddenField(\$(#$i->{raiseDOMId}#), #pk#, pk); \$(#$i->{raiseDOMId}#).setStyle({left:Event.pointer(event).x, top: Event.pointer(event).y}).appear({duration:0.15});" if($i->{raiseDOMId});
			$i->{callback}='function(e) {dbweb.submitCTXAction(e,\''.$i->{confirm}.'\',\''.$i->{javascript}.'\','.$i->{action}.',\''.$i->{perlfunc}.'\',\''.$dgn.'\') }';
			delete $i->{$_} for qw/perlfunc confirm javascript action condition raiseDOMId/;
			$i;
		} @$cm;
		my $json=JSON::XS->new->utf8->encode(\@arr);
		$json =~s/\"//gos;
		$json =~s/#/\"/ogs;
		$ret->{$dgn}={selector=>'DG_'.$dgn, items=> $json};
	}
	return $ret;
}

sub splitFromFormatString { my ($valS,$formatS)=@_;
	my $ret={};

	my @fa=split /%/o, $formatS;
	shift @fa;
	for(@fa)
	{	my ($c,$s)=$_=~/^(.)(.*)/o;
		if(length $s)
		{	$valS=~s/^(.*?)\Q$s\E//es;
			$ret->{$c}=$1;
		} else { $ret->{$c}=$valS; }
	} return $ret;
}

sub y2kThreshold {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime;
	return $year-50;	# "year of common era" (near to 50)
}
sub addAttribsOfFilterToDictForDGN { my ($filterName,$udict,$dgName)=@_;
	my $additionalAttribs=whereClauseForFilterOfDGName($filterName,$dgName);
	$udict->{$_}=$additionalAttribs->{$_} for (keys %{ $additionalAttribs });
}

sub decodeCGI { my ($name)=@_;
	my $val=$dbweb::cgi->param($name);
	Encode::_utf8_on($val);
	return $val;
}
sub read_post {
	use APR::Brigade ();
	use APR::Bucket ();
	use Apache2::Filter ();
  	use Apache2::Connection;
	use Apache2::Const -compile => qw(MODE_READBYTES);
	use APR::Const    -compile => qw(SUCCESS BLOCK_READ);
  
	use constant IOBUFSIZE => 8192;
      my $r = shift;
  
      my $bb = APR::Brigade->new($r->pool,
                                 $r->connection->bucket_alloc);
  
      my $data = '';
      my $seen_eos = 0;
      do {
          $r->input_filters->get_brigade($bb, Apache2::Const::MODE_READBYTES,
                                         APR::Const::BLOCK_READ, IOBUFSIZE);
  
          for (my $b = $bb->first; $b; $b = $bb->next($b)) {
              if ($b->is_eos) {
                  $seen_eos++;
                  last;
              }
  
              if ($b->read(my $buf)) {
                  $data .= $buf;
              }
  
              $b->remove; # optimization to reuse memory
          }
  
      } while (!$seen_eos);
  
      $bb->destroy;
  
      return $data;
}

sub dataDictFromCGIForDGName { my ($dgName, $col)=@_;
	my $udict={};
	my $formInfo=sessionData('forminfo_'.decodeCGI('forminfo'));
	my $currCol;
	my @columns = $col? ($col): (keys %{$formInfo->{snapshot}});
	@columns=@{$dbweb::displayGroups->{$dgName}->{columns}} if(scalar @columns==0 && (exists $dbweb::displayGroups->{$dgName})) ;
	foreach $currCol (@columns)
	{	my ($uplFH, $currVal);
		$dbweb::FILENAME=$dbweb::apache->headers_in()->get('X-Filename');
		if($dbweb::FILENAME)
		{	$currVal=read_post ($dbweb::apache);
		} elsif (length ( $uplFH=$dbweb::cgi->upload($dgName.'_'.$currCol)))
		{	$dbweb::FILENAME=$uplFH->filename;
			$uplFH->slurp($currVal);
		} else
		{	if($col)
			{	$currVal= decodeCGI('value');
			} else
			{	$currVal= decodeCGI($dgName.'_'.$currCol);
			}
		}

		my  $formatinfo=$formInfo->{'format'}->{$currCol};
		$currVal =(length $currVal)?1:0 if ($formatinfo eq 'bool');		# <!> eleganter: ueber den datatype gehen und aus dem forminfo eliminieren

		if(exists $dbweb::displayGroups->{$dgName} && !$col)		# nicht skippen bei unbound (search) DGs
		{	next unless(length $currVal || length $formInfo->{'snapshot'}->{$currCol} );	# weder im snapshot noch in der eingabe ein wert -> nicht schreiben
			next if($currVal eq $formInfo->{'snapshot'}->{$currCol} );	# gleicher wert wie im snapshot-> nicht schreiben
		}
		$udict->{$currCol}=$currVal;

		if ($formatinfo =~/date:(.*)/ois)
		{	my $format=$1;
			my $kvD=splitFromFormatString($currVal ,$format);
			$kvD->{$_}||='1' for qw/d m/;

# <!> server side date validation: discard date when len year !=2 or 4, month... und jahreskomponente ggf. ergaenzen wenn weggelassen

			if(length $currVal)	# besser waere: (scalar keys %{$kvD} >=3)
			{	$kvD->{'Y'}=($kvD->{'y'}> y2kThreshold()? '19':'20').$kvD->{'y'} if(defined $kvD->{'y'} && length $kvD->{'y'}==2);

				$kvD->{'Y'}=($kvD->{'Y'}> y2kThreshold()? '19':'20').$kvD->{'Y'} if(defined $kvD->{'Y'} && length $kvD->{'Y'}==2);
				$kvD->{'Y'}= $kvD->{'y'} if(defined $kvD->{'y'} && length $kvD->{'y'}==4);

				$udict->{$currCol}=$kvD->{'Y'}.'-'.$kvD->{'m'}.'-'.$kvD->{'d'};
				if(defined $kvD->{'H'})
				{	$udict->{$currCol}.=' '.$kvD->{'H'}.':'.$kvD->{'M'};
					$udict->{$currCol}.=':'.$kvD->{'S'} if (defined $kvD->{'S'});
				}
			} else {$udict->{$currCol}=\$dbweb::globalNullObject };		# format error bei datum
		} elsif(exists $dbweb::displayGroups->{$dgName} && exists $dbweb::displayGroups->{$dgName}->{types})
		{	$udict->{$currCol}=\$dbweb::globalNullObject if((!length $currVal) && $dbweb::displayGroups->{$dgName}->{types}->{$currCol} eq 'int');
		}

		my	$comboinfo=$formInfo->{'combo'}->{$currCol};
		if(length $comboinfo)
		{	my ($displayGroupName,$fieldName,$filterName)=($comboinfo->{dg},$comboinfo->{field},$comboinfo->{filter});
			my $dg=$dbweb::displayGroups->{$displayGroupName};
			my $sdict={$fieldName => $currVal};
			addAttribsOfFilterToDictForDGN($filterName,$sdict,$displayGroupName) if(length $filterName);
			my $substID=getRawDataForDG($dg, $sdict )->[0]->[getIndexOfColumnInDG($dg->{primaryKey},$dg)];
			if(length $substID)
			{	$udict->{$currCol}=$substID;
			} else
			{	my $allowsInsert=0;
				if($allowsInsert)
				{	$udict->{$currCol}=insertDictIntoTable(getDBHForDG($dg),$sdict,(length $dg->{write_table})? $dg->{write_table}:$dg->{table}, $dg->{types}, $dg->{primaryKey});
				} else
				{	delete $udict->{$currCol};
				}
			}
		}
		$udict->{$currCol}=\$dbweb::globalNullObject if((!length $currVal) && $formInfo->{'nullify'}->{$currCol});		#popup, combo, date, combo
		delete $udict->{$currCol} if(!defined $dbweb::displayGroups->{$dgName} && (!length $udict->{$currCol} || isNull($udict->{$currCol}) ) ); #convenience for unbound searchDGs
	} return $udict;
}

sub invalidateDisplayGroupsDependingOnDGName { my ($dgName)=@_;
	my $currKey;
	foreach $currKey (keys(%{$dbweb::displayGroups}))
	{	if(displayGroupDependsOnSelectionOfDGN($currKey,$dgName))
		{	sessionData('selectedID_'.  $currKey, '');
			nullifySessionPrefix('forminfo_'.$currKey);
		}
	}
}

sub insertDictIntoCache { my ($displayGroup,$udict)=@_;
	my $dgName=nameOfDG($displayGroup);
	my $data=sessionData('cache_'.$dgName);
	$data=[] if((!length $data) || ($#{$data}<0));
	my @arr;
	map { $arr[getIndexOfColumnInDG($_,$displayGroup)]=$udict->{$_} } ( keys %{$udict} );
	push(@{$data},\@arr);
	sessionData('cache_'.$dgName,$data);
}
sub removeWhereDictFromCache { my ($displayGroup,$wheredict)=@_;
	my $dgName=nameOfDG($displayGroup);
	my $data=sessionData('cache_'.$dgName);
	if((length $data) && ($#{$data}>=0))
	{	my $code = eval(evalCacheCriteriaInDGForWhereClause($displayGroup, $wheredict));
		$dbweb::logger->log_error(":$@") if(length $@);
		$data = [ grep { ! $code->($_) } @{$data} ];
		sessionData('cache_'.$dgName, $data);
	}
}

sub updateAttriutesOfDGNForWhereClause { my ($dict1, $dgName, $wheredict, $dbh, $options, $types)=@_;
	my $displayGroup=$dbweb::displayGroups->{$dgName};

	if(length $displayGroup->{DataInSession} )
	{	my $udict=sessionData('session_'.$dgName);
		$udict->{$_}=isNull($dict1->{$_}) ? undef: $dict1->{$_} for( keys %{$dict1} ) ;
		sessionData('session_'.$dgName,$udict);
		return;
	}
	my $tableName=(defined $displayGroup->{write_table})? $displayGroup->{write_table}:$displayGroup->{table};
	$dbh=getDBHForDG($displayGroup) if(!defined($dbh) && length $tableName);
	updateAttriutesOfTableForWhereClause($dbh, $dict1,$tableName,$wheredict,$types) if($dbh && !$options->{cacheOnly});

	# now write through changes to cache
	my $data=sessionData('cache_'.$dgName);
	if($data && scalar @$data)
	{	my $code=evalCacheCriteriaInDGForWhereClause($displayGroup,$wheredict);
		my $coderef=eval $code; $dbweb::logger->log_error(":$@") if(length $@);

		for (grep { $coderef->($_) } ( @{$data} ) )		# "database-search"
		{	my $currKey;
			while( my($currKey, $currVal)= each %{$dict1})	# "database-update"
			{
				$_->[getIndexOfColumnInDG($currKey,$displayGroup)]= isNull($currVal) ? undef: $currVal; 
			}
		}
		sessionData('cache_'.$dgName, $data);
	}
}

sub updateSearchDGForDGAndDict { my ($displayGroup,$udict)=@_;
	my $whereclauseDict=sessionData ( 'where_'.$displayGroup->{bindToDG});
	if(length $whereclauseDict)
	{	$whereclauseDict={};
		map { $whereclauseDict->{$_}=$udict->{$_}  } ( keys %{$udict} );
		sessionData('where_'.$displayGroup->{bindToDG}, $whereclauseDict);
	}
}

sub logToUndoStack { my ($action, $displayGroup, $newvals, $oldvals, $wheredict)=@_;
	my $undoDG=getUndoDGForDG($displayGroup);
	my $dgName=nameOfDG($displayGroup);
	if($undoDG)
	{	my($where_key, $where_val)= each %$wheredict;
		my $d={action=>$action, dg=> $dgName, timestamp=> time()};
		$d->{newvals}=	$newvals	if($newvals);
		$d->{oldvals}=	$oldvals	if($oldvals);
		$d->{pk}=$where_val			if($where_val);
		my $dbh= getDBHForDG($undoDG);
		if($dbh)
		{	insertDictIntoTable($dbh, $d, $undoDG->{table}, $undoDG->{types});
		} else	# in-memory data
		{	insertDictIntoCache($undoDG, $d);
		}
	}
}


sub getCGIParam { my ($param, $fi)=@_;
# <!> upon whitelist-secured comm this function will simply return $fi->{$param};
	return (length decodeCGI($param)) ? decodeCGI($param): $fi->{$param};
}
sub CGIonlyDigits { my ($param)=@_;
	my $val=decodeCGI($param);
	$val=~/^([+\-0-9]+)/o;
	return $1;
}
sub CGIonlyAlphanum { my ($param)=@_;
	my $val=decodeCGI($param);
	$val=~s/[^0-9\.\/a-z_ ]//oigs;
	return $val;
}
sub CGIonlyAlphanumStrict { my ($param)=@_;
	my $val=decodeCGI($param);
	$val=~s/[^0-9a-z_]//oigs;
	return $val;
}

#<!> rename all lexicals (esp. $udict) by means of prefixing __ (to secure api)
sub performDisplayGroupActions {
	# performing the appropriate action inspired by last request is an _ordered_ multistep process...
	#
	# step 0: collect action requests and parameters from ste $dbweb::cgi
	my $fi=sessionData('forminfo_'.decodeCGI('forminfo'));

	my $action=			 getCGIParam('a',$fi);
	my $primaryKey=		 getCGIParam('pk',$fi);		#<!> whitelist
	my $dgName=			 getCGIParam('dg',$fi);
	my $updateRequested= getCGIParam('u',$fi);
	my $perlform=		 getCGIParam('fn',$fi);
	my $actionform=		 getCGIParam('fna',$fi);

	my $cascadedSelect=(CGIonlyDigits('cs') eq '1');
	my $inplace=		CGIonlyAlphanum ('inplace');
	my ($connDict, $dbh, $udict);

	# process ajax requests
	if($dbweb::currentAjaxState == 1)		# sciptaculous autocompleter
	{	my ($offset,$pagesize,$field,$filter, $pk)=(	CGIonlyDigits('offset'), CGIonlyDigits('page_size'), CGIonlyAlphanum('field'), CGIonlyAlphanum('filter'),
								CGIonlyAlphanum('pk') );
		my $val=decodeCGI('fieldvalue');
		my $d={offset=> $offset, length=>$pagesize, filter=>$filter,  };
		if(length $val)
		{	$d->{whereClause}={$field=>$val};
			$d->{like}={$field=>1};
		}
		$d->{whereClause}->{$dbweb::displayGroups->{$dgName}->{bindFromColumn}}=$pk
			if(length $pk && $dbweb::displayGroups->{$dgName}->{bindFromColumn});
		my $data=getDataForDGN($dgName, $d );
		if($#{$data}>-1)
		{	my $pkIndex= getIndexOfColumnInDG($field,$dbweb::displayGroups->{$dgName});
			my $ret= join("</li>\n<li>", map { encode_entities($_->[$pkIndex]) } (@{$data}) );
			$dbweb::apache->content_type('text/html; charset=UTF-8');
			$dbweb::apache->print('<ul><li>'.$ret.'</ul>');
		}
		return 1;
	} elsif($dbweb::currentAjaxState == 2)		#  livedatagrid
	{	my $idname=decodeCGI('id');
		my $foreachblock=sessionData('ajaxtab_'.$idname);

		my ($offset,$pagesize,$filter)=(CGIonlyDigits('offset'), CGIonlyDigits('page_size'), CGIonlyAlphanum('filter') );
###		warn "offset: ".$offset." length: ".$pagesize." filter: ".$filter;
		my $data= handleForeach($dgName, $foreachblock, {offset=> $offset, length=>$pagesize, filter=>$filter});
		my @rows=split /<\/tr>/o, $data;
		@rows= map {$_=~s/^<t[rd](\s*class=\"([^\"]+)\"){0,1}[^>]*?>+\s*//ogs; [$2,$_]} @rows;
		$dbweb::apache->content_type('text/json; charset=UTF-8');
		my $val=JSON::XS->new->utf8->encode(\@rows);
		$dbweb::apache->print($val);
###		warn $val;
		return 1;
	} elsif($dbweb::currentAjaxState == 3)	# livegrid table offset recording
	{	my $idname=CGIonlyAlphanum('id');
		my $row=decodeCGI('topline');
		$row=0 unless $row=~/^[0-9]+$/o;
		sessionData('row_'.$idname, $row);
		return 1;
	} elsif($dbweb::currentAjaxState == 4)		# session GLOBAL interfacing
	{	my $idname=CGIonlyAlphanum('id');
		$dbweb::apache->content_type('text/html; charset=UTF-8');
		$dbweb::apache->print(getGlobal($idname) );
		return 1;
	} elsif($dbweb::currentAjaxState == 9)		# change sorting
	{	my $name= CGIonlyAlphanumStrict('name');
		my $dg;
		$dg=$dbweb::displayGroups->{$dgName} if( exists $dbweb::displayGroups->{$dgName} );
		if($dg && exists $dg->{sortColumns} && exists $dg->{sortColumns}->{$name})
		{	sessionData('defaultsortfilter_'.$dgName, $name);
			my $oldval= sessionData('defaultsortupdown_'.$dgName);
			sessionData('defaultsortupdown_'.$dgName, $oldval=~/down/? 'up':'down');
		}
	} elsif($inplace)		# inplace editor
	{	my $field = ($inplace =~ /^$dgName\_(.*)/)? $1 : undef;
		if($field)
		{	$udict = dataDictFromCGIForDGName($dgName,$field);
			$dbweb::ajaxReturn{element}=CGIonlyAlphanum('id');
			$dbweb::ajaxReturn{pk}=$primaryKey;
		}
	} else
	{	$udict=dataDictFromCGIForDGName($dgName) unless($action eq 'select');
###		warn Dumper($udict);
	}

	# delete $dbweb::session{$_} grep {/^forminfo_.*?$dbweb::APPNAME$/} keys ( %dbweb::session ); 	# forminfo garbage collection <!> UNTESTED

	$dbh= getDBHForDG($dbweb::displayGroups->{$dgName}) if(defined $dbweb::displayGroups->{$dgName} && defined $dbweb::displayGroups->{$dgName}->{table});

	# step 0: perform custom perl code
	#
	my $__invokeParam='';
	eval(getPerlfuncCode($perlform)) if(length $perlform); $dbweb::logger->log_error(":$@") if(length $@);
	eval(getPerlfuncCode('_autoform_'));  $dbweb::logger->log_error(":$@") if(length $@);

	# step 1: perform database updates
	#
	if( $updateRequested eq 'y')
	{
		if(defined $dbweb::displayGroups->{$dgName})
		{	my $displayGroup=$dbweb::displayGroups->{$dgName};
			if(length $displayGroup->{table} || length $displayGroup->{cache})
			{	my $csel= selectedIDOfDisplayGroupName($dgName);
				my $sel=(length $primaryKey)? $primaryKey:$csel;

				if(length $sel && defined $displayGroup->{primaryKey}  && defined $udict) 	# see abortPendingUpdate api func
				{	my $wheredict= { $displayGroup->{primaryKey}=>$sel };
					delete $udict->{$_} for (@{ $displayGroup->{suppress_update} });

					#	compare snapshot to current db state
					if(length $displayGroup->{table})
					{	my $dg=$dbweb::displayGroups->{$dgName};
						my $currDatarow=getRawDataForDG($dg, $wheredict);
						my $oldvals={};
						my $different=0;
						foreach my $ckey (keys %$udict)
						{	$oldvals->{$ckey}=$currDatarow->[0]->[ getIndexOfColumnInDG($ckey, $dg) ];
							$different |= ($oldvals->{$ckey} ne $fi->{'snapshot2'}->{$ckey});
							$fi->{'snapshot2'}->{$ckey}=$udict->{$ckey};	# inplace-editing has to update snapshot in order to avoid false positives
						}
						if($different)
						{	if ($dbweb::ajaxReturn{element}  && $inplace)
							{	$dbweb::ajaxReturn{oldval}{$dbweb::ajaxReturn{element}}=$oldvals->{$inplace};
								$dbweb::ajaxReturn{error}{$dbweb::ajaxReturn{element}}='snapshot inconsistent with database (concurrent update from multiple sessions?)';
							}
						}
						logToUndoStack('update',$displayGroup,dbweb::stringFromProperty($udict), dbweb::stringFromProperty($oldvals),$wheredict);
					}
					updateAttriutesOfDGNForWhereClause($udict, $dgName, $wheredict, $dbh, undef, $displayGroup->{types});
					# now update searchDG to still point to updated record
					if((length $displayGroup->{bindToDG}) && !( defined  $dbweb::displayGroups->{$displayGroup->{bindToDG} } ) )	
					{	updateSearchDGForDGAndDict($displayGroup,$udict);
					}
				}
			} elsif(defined $dbweb::displayGroups->{$dgName}->{DataInSession} )
			{	updateAttriutesOfDGNForWhereClause($udict, $dgName);
				invalidateDisplayGroupsDependingOnDGName($dgName) if $displayGroup->{primaryKey} && exists $udict->{$displayGroup->{primaryKey} };
			} elsif(defined $dbweb::displayGroups->{$dgName}->{data})
			{	sessionData('selectedID_'.$dgName, $udict->{$displayGroup->{primaryKey}}) if (exists $udict->{$displayGroup->{primaryKey}});
			}
		} else
		{	sessionData('where_'.$dgName,$udict);
			sessionData('haswhere_'.$dgName,1);
			invalidateDisplayGroupsDependingOnDGName($dgName);
		}
	}

	# step 2: change selection when requested
	if($action eq 'select')
	{	my  $dg=$dbweb::displayGroups->{$dgName};
		if( $dg && exists $dg->{DataInSession})
		{	updateAttriutesOfDGNForWhereClause({$dg->{primaryKey}=> $primaryKey}, $dgName);
		} else
		{	sessionData('selectedID_'.$dgName, $primaryKey);
		}
		invalidateDisplayGroupsDependingOnDGName($dgName);
		if($cascadedSelect)		# cascadedSelect auswerten: alle where-clauses muessen auf die angefragte SEL verweisen
		{	my $tdg;
			my $tpk=$primaryKey;
			my $ndgn;
			for($tdg=$dbweb::displayGroups->{$dgName}; $ndgn=$tdg->{bindToDG},length $ndgn; $tdg=$dbweb::displayGroups->{$ndgn})
			{	if(defined $dbweb::displayGroups->{$ndgn})
				{	$tpk=getColumnsOfTableForDict($dbh,[$tdg->{bindFromColumn}],$tdg->{table}, { $tdg->{primaryKey}=>$primaryKey }, { types=>$tdg->{types} } )->[0]->[0];
					sessionData('selectedID_'.$ndgn, $tpk);
					sessionData('where_'.$ndgn , {$dbweb::displayGroups->{$ndgn}->{primaryKey}=>$tpk});
				} else
				{	sessionData('where_'.$ndgn , { $tdg->{primaryKey} => $tpk });
				} sessionData('haswhere_'.$ndgn,1);
			}
		}
	} elsif ($action eq 'delete')
	{	my $displayGroup=$dbweb::displayGroups->{$dgName};
		my $sel= (length $primaryKey)? $primaryKey: selectedIDOfDisplayGroupName($dgName);
		if(defined $sel && defined $displayGroup->{primaryKey})
		{	my $wheredict={$displayGroup->{primaryKey}=>$sel};
			my $currDatarow=getRawDataForDG($displayGroup, $wheredict);
			my $oldvals={};
			foreach my $ckey (@{$displayGroup->{columns}})
			{	$oldvals->{$ckey}=$currDatarow->[0]->[ getIndexOfColumnInDG($ckey, $displayGroup) ];
			}
			logToUndoStack('delete',$displayGroup, undef, dbweb::stringFromProperty($oldvals), $wheredict);
			removeRowsForWhereClause($dbh,(length $displayGroup->{write_table})? $displayGroup->{write_table}:$displayGroup->{table},
										  $wheredict,$displayGroup->{types})  if($dbh);
			removeWhereDictFromCache($displayGroup, $wheredict) if($displayGroup->{cache});
			sessionData('selectedID_'.$dgName, '');
			invalidateDisplayGroupsDependingOnDGName($dgName);
		}
	} elsif (($action eq 'insert'  && !$inplace) || $action eq 'deleteall')
	{	my $displayGroup=$dbweb::displayGroups->{$dgName};
		if(defined $displayGroup->{primaryKey} && defined $udict) 	# see abortPendingInsert api func
		{	$udict={} if($action eq 'deleteall');
			my $filterName=$fi->{'addColsFromFilter'};

			addAttribsOfFilterToDictForDGN($filterName,$udict,$dgName) if(length $filterName);
			if(defined $displayGroup->{bindFromColumn} && defined $displayGroup->{bindToDG})
			{	$udict->{$displayGroup->{bindFromColumn}}=selectedIDOfDisplayGroupName($displayGroup->{bindToDG});
			}
			delete $udict->{$_} for (@{ $displayGroup->{suppress_insert} });
			if($action eq 'insert')
			{	my $pk;
				if($dbh)
				{	my $tableName=(length $displayGroup->{write_table})? $displayGroup->{write_table}:$displayGroup->{table};
					$pk=insertDictIntoTable($dbh,$udict,$tableName, $displayGroup->{types}, $displayGroup->{primaryKey});
				}
				if($displayGroup->{cache})
				{	if(length $pk) { $udict->{$displayGroup->{primaryKey}}=$pk }
					else { $pk=$udict->{$displayGroup->{primaryKey}} }
					insertDictIntoCache($displayGroup,$udict);
				}
				sessionData('selectedID_'.$dgName, $pk);
				# now update searchDG to point to inserted record
				updateSearchDGForDGAndDict($displayGroup,$udict) unless( defined ( $dbweb::displayGroups->{$displayGroup->{bindToDG}} ));
				logToUndoStack('insert',$displayGroup, undef, dbweb::stringFromProperty($udict), {$displayGroup->{primaryKey}=>$pk} );
			} else	#  delete all
			{	removeRowsForWhereClause($dbh,(length $displayGroup->{write_table})? $displayGroup->{write_table}:$displayGroup->{table},$udict)
					if($dbh);
				removeWhereDictFromCache($displayGroup,$udict) if($displayGroup->{cache});
				sessionData('selectedID_'.$dgName, '');
			}
		} invalidateDisplayGroupsDependingOnDGName($dgName);
	}
	# step 3: garbage collection
	nullifyForList(['ajaxtab'] , $dbweb::APPNAME);	#gc
###	warn "currentAjaxState is: $dbweb::currentAjaxState";

	# step 4: perform action perl code
	#
	eval(getPerlfuncCode($actionform)) if(length $actionform && $updateRequested eq 'y' && !$inplace); $dbweb::logger->log_error(":$@") if(length $@);
	# step 5: error handling
	#
	$dbweb::ajaxReturn{error}{ $dbweb::ajaxReturn{element}}=$DBI::errstr if($DBI::errstr && $dbweb::ajaxReturn{element});
	return 1 if($dbweb::_isMuted);

	if($dbweb::currentAjaxState == 8)		# dummy upload return
	{	$dbweb::apache->content_type('text/html; charset=UTF-8');
		$dbweb::apache->print('<h1>Upload complete. Press Back-Button to continue</h1>');
		return 1;
	}

	return 0;
}
sub nullifyForList { my ($nl,$select)=@_;
	nullifySessionPrefix($_.'_',$select)  for( @{ $nl } );
}

sub handleErrors { my ($block,$text)=@_;
	return '' unless(length $text);
	$block=~ s/<error\/>/$text/oigs;
	return $block;
}

# initialize globals
sub initGlobals{
	$dbweb::globalNullObject=0;
	$dbweb::displayGroups={};
	$dbweb::_uniqueID=0;
	%dbweb::_globalDGIdentifier=();
	%dbweb::JSConfigs=();
	$dbweb::sessionid='';
	%dbweb::session=();
	%dbweb::_dbhH=();
	%dbweb::_dbhE=();
	%dbweb::perlFuncs=();
	%dbweb::ajaxReturn=();
	$dbweb::dbi_error='';
	$dbweb::_isMuted=0;		# for PDF output
	$dbweb::currentAjaxState=0;

	$dbweb::loginname='login';

	$dbweb::SQL_LIMIT=0;	#postgres:0 ora: 1
	$dbweb::SQL_CP='AS __a';
	$dbweb::SQL_TQL='"';	# oracle: 'AUGDBA.'
	$dbweb::SQL_TQR='"';	# oracle: ''

	$dbweb::FILENAME='';
}

# confgure "bootstrap" client-side javascript package
sub activateApplication { my ($appname, $adduri)=@_;
	$appname=$dbweb::loginname unless length $appname;
	if($dbweb::currentAjaxState == 7)
	{	my $uri= (length $dbweb::sessionid)? $dbweb::URI.'?sid='.$dbweb::sessionid.'&ajax=0&t='.$appname.$adduri: $dbweb::URI;
		$dbweb::apache->content_type('json/html; charset=UTF-8');
		$dbweb::apache->print( JSON::XS->new->utf8->encode( {redir_loc=> $uri } ) );
	} else
	{	$adduri='&a=select&dg='.decodeCGI('dg').'&pk='.decodeCGI('pk').'&cs=1' if(decodeCGI('cs'));

		my $template= getJSCode();
		$template=~s/__APPNAME__/$appname/ogs;
		$template=~s/__SESSIONID__/$dbweb::sessionid/ogs;
		$template=~s/__URI__/$dbweb::URI/ogs;
		$template=~s/__ADDURI__/$adduri/ogs;
		my $apress=$dbweb::pathAddendum.'/'.$dbweb::APPNAME;
		$template=~s/__APPRESS__/$apress/ogs;
		$template=~s/__ADDHTML__/$ENV{$dbweb::handlerName.'_additinal_html_'.$dbweb::pathAddendum}/ogs;

		$dbweb::apache->content_type('text/html; charset=UTF-8');
		$dbweb::apache->print($template);
	}
	$dbweb::_isMuted=1;
}

########################## 
sub handler{
	$dbweb::apache= shift;

	initGlobals();

	$dbweb::SQLDEBUG=2;	# 1 shows all SQL, 2 shows only updates
	$dbweb::DEBUG   =1;

	$dbweb::pathPrefix=$main::ENV{dbwebressourceurl};
	$dbweb::pathPrefix='/dbwebressources/' unless length $dbweb::pathPrefix;

	$dbweb::URI=$dbweb::apache->uri;	 # e.g. /dbweb/hhb
	$dbweb::handlerName='dbweb';
	$dbweb::pathAddendum='';
   ($dbweb::handlerName, $dbweb::pathAddendum)=($1, $2) if($dbweb::URI =~/\/([^\/]+)[\/]*(.*)/o);

	$dbweb::cgi = Apache2::Request->new($dbweb::apache); 
	$dbweb::logger = Apache2::ServerUtil->server;

	$dbweb::sessionid=$1 if(decodeCGI('sid')=~/^(.*)/);	#untaint

	my $forcedRedirect=decodeCGI('t');
	if(length $forcedRedirect)
	{	$dbweb::currentAjaxState=0;
	} else
	{	$dbweb::currentAjaxState=CGIonlyDigits('ajax');
		$forcedRedirect=$dbweb::loginname unless length $dbweb::currentAjaxState;
		$dbweb::currentAjaxState=0 if($dbweb::currentAjaxState> 12 || $dbweb::currentAjaxState<0 || (!length $dbweb::currentAjaxState));

	}

	if(decodeCGI('cc'))									#logout
	{	unlink('/tmp/'. $dbweb::sessionid);							#delete session data
		unlink('/tmp/Apache-Session-'. $dbweb::sessionid.'.lock');
		$dbweb::sessionid=undef;
		activateApplication($dbweb::loginname);
		return OK;
	} elsif(my $f= CGIonlyAlphanum('pf'))
	{	my $d= (-e '/tmp/'.$f);
		$dbweb::apache->content_type('json/html; charset=UTF-8');
		$dbweb::apache->print( JSON::XS->new->utf8->encode( {exists=>$d} ) );
		return OK;
	}
	else
	{	if(length $dbweb::sessionid && !-e '/tmp/'. $dbweb::sessionid)
		{	$dbweb::sessionid=undef;
			loginerror();
		}
	}
__HANDLER__: while(1){
	tie %dbweb::session, 'Apache::Session::File', (length $dbweb::sessionid)? $dbweb::sessionid:undef , {Transaction => 1};
	warn 'session storage failed (disk full?, permissions?)' unless %dbweb::session;
	$dbweb::sessionid = $dbweb::session{_session_id} unless length $dbweb::sessionid;

	if(length $forcedRedirect)
	{	nullifyForList(['selectedID','where','haswhere','forminfo','row'], $forcedRedirect);
		$dbweb::APPNAME=$forcedRedirect;
	} else
	{	$dbweb::APPNAME=decodeCGI('pt');
	}
	my @a=split /\//o, $dbweb::pathAddendum; $dbweb::pathAddendum=$a[0];
	$dbweb::APPNAME=$a[1] if((scalar @a >1) && !(length $dbweb::APPNAME));
	$dbweb::APPNAME=$dbweb::loginname unless(length $dbweb::APPNAME);
	my $templateFileName=$dbweb::pathPrefix.$dbweb::pathAddendum.'/'.$dbweb::APPNAME.'.dgwapp';

	my $template;
	# confgure "bootstrap" client-side javascript package
	if($forcedRedirect)
	{	activateApplication($dbweb::APPNAME);
		last __HANDLER__;
	} else
	{	$template = $1 if(LWP::Simple::get($templateFileName) =~/(.*)/os);	# untaint
###		warn "$template $templateFileName";
	}

	# step 1: register display groups in global variable $displayGroups, the same for perlfuncs in %dbweb::perlFuncs
	$template=~s/<include src=\"([^\"]+)\">/LWP::Simple::get($dbweb::pathPrefix.$1)/oegs;
	$template=~s/<comment>(.*?)<\/comment>//ogsi;	# kommentare rausloeschen
	$template=~s/<perlfunc(.*?)>(.*?)<\/perlfunc>/registerPerlfuncs($1,$2)/oegs;

	$template=~s/<DisplayGroups([^>]*)>(.*?)<\/DisplayGroups>/registerDisplayGroups($1, $2)/oegs;
	*{'DG::'.$_}=\$dbweb::displayGroups->{$_} for keys %{$dbweb::displayGroups};
	bless  $dbweb::displayGroups->{$_}, 'DG'  for keys %{$dbweb::displayGroups};

	$template=~s/\s+/ /ogs;	# compact by minimizing whitespaces
	$template=~s/<useperl\s+module\s*=\s*["]?([^">]+)["]?\s*>/registerPerlmodule($1)/oegs;
	eval(getPerlfuncCode('_onload_')) if(decodeCGI('first')); $dbweb::logger->log_error(":$@") if(length $@);
	eval(getPerlfuncCode('_bootstrap_'));  $dbweb::logger->log_error(":$@") if(length $@);

	# step 2: perform action inspired by last request
	last __HANDLER__ if(performDisplayGroupActions());
	# step 2a: give app a chance to respond
	eval(getPerlfuncCode('_earlyauto_')); $dbweb::logger->log_error(":$@") if(length $@);

	# step 3: load data from displayGroups into the foreach templates
	$template=~s/<table:(.*?)>(.*?)<\/table.*?>/handleTable($1,$2)/oegs;
	while($template=~s/<(condDG|foreach):([^>]+)>(.*?)<\/\1>/$1 eq 'foreach' ? handleForeach($2,$3):handleCond($2,undef,$3)/oeis){};

	# step 3a: conditional stuff and countings
	$template=~ s/<condDG:([^>]+?)\b([^>]*?)>(.*?)<\/condDG:\1>/handleCond($1,$2,$3)/oeigs;		# fully qualified close tag allows for nested conds 
	$template=~s/<countDG:([^>]+?)\b([^>]*?)>/handleCounts($1,$2)/oeigs;
	# step 4: handle forms
	$template=~s/<form:(.+?)\b(.*?)>(.*?)<\/form>/handleForm($1,$2,$3)/oeigs;

	# step 5: expand static links
	$template=~s/<link:([^\s]+) display=\"([^\"]+)\">/<a href=\"javascript:dbweb.S('$1')\">$2<\/a>/oigs;
	$template=~s/<link:(.*?)>/<a href=\"javascript:dbweb.S('$1')\">$1<\/a>/oigs;
	$template=~s/<logout>/<a href=\"javascript:dbweb.saveAndLogout();\">logout<\/a>/oigs;	

	# step 6: handle displayGroup action-buttons
	$template=~s/<button:(.+?)\b(.*?)>/handleButton($1,$2)/oeigs;
	$template=~s/<displayGroup:(.*?)>/handleAction($1)/oeigs;

	# step 9: execute autocode
	eval(getPerlfuncCode('_auto_')); $dbweb::logger->log_error(":$@") if(length $@);

	last __HANDLER__ if $_isMuted;

	$template=~ s/<onerror:dbi>(.*?)<\/onerror:dbi>/handleErrors($1,$dbweb::dbi_error)/oeigs;
	$template=~ s/<onerror:perl>(.*?)<\/onerror:perl>/handleErrors($1,$@)/oeigs;

	# step 10: print result
	sub extractScripts{ my ($s, $sr)=@_;
		$$sr.= $s;
		return '';
	}
	my $scripts;
	$template=~ s/<script>(.*?)<\/script>/extractScripts($1,\$scripts)/oeigs;
	$dbweb::JSConfigs{contextmenu}=compileContextMenus();

	my $inplaceData;
	if ($dbweb::ajaxReturn{element})
	{	my $key=$dbweb::ajaxReturn{element};
		my $val=$dbweb::ajaxReturn{values}{$key};
		my $old=$dbweb::ajaxReturn{oldval}{$key};
		$inplaceData={key=>$key, val=>decode_entities($val), oldval=> decode_entities( $old), pk=> $dbweb::ajaxReturn{pk}} if exists $dbweb::ajaxReturn{values}{$key};
	}

	my $d={appname=>$dbweb::APPNAME, jsconfig=>\%dbweb::JSConfigs, scripts=>$scripts, page=>$template, inplace=>$inplaceData, reload=>(length $dbweb::dbi_error)?1:0, id=>$dbweb::ajaxReturn{element} };

###	warn encode_json( $d );
	$dbweb::apache->content_type('json/html; charset=UTF-8');
	$dbweb::apache->print( JSON::XS->new->utf8->encode( $d ) );
	eval(getPerlfuncCode('_lateauto_'));  $dbweb::logger->log_error(":$@") if(length $@);

	last}
	__exit__:

	disconnectAllDBHs();
	untie %dbweb::session;

	return OK;
}

#################################################################################
sub getAPICode { return <<'__APIEOF__'
#
# the part of the api package, that needs access to lexicals within
# performDisplayGroupActions() or handler();
##################################################################################
package DG;

sub callerButtonName{
	return $fi->{buttonname};
}
sub mutablePendingInsertionDict{
	return $udict;
}
sub pendingUpdateDict { my ($self)=@_;
	return dbweb::dataDictFromCGIForDGName(dbweb::nameOfDG($self)) ;
}
sub mutablePendingUpdateDict{
	return $udict;
}
sub abortPendingInsert{
	$udict=undef;
}
sub abortPendingUpdate{
	$udict=undef;
}
sub disableButton{ my ($button, $template2)=@_;
	_disableButton($button, $template2? $template2:\$template );
}
sub disableUIElement{ my ($self, $button, $template2)=@_;
	$self->_disableUIElement($button, $template2? $template2:\$template );
}
sub removeUIElement { my ($self, $button, $template2)=@_;
	$self->_removeUIElement($button, $template2? $template2:\$template );
}
sub pendingPrimaryKey{
	return $primaryKey;
}
__APIEOF__
}
# client-side javascript package
###################################################################################
sub getJSCode { return <<'__JSEOF__'
<html>
<head>
<link rel=stylesheet href="/dbwebressources/style.css"/>
<link rel=stylesheet href="/dbwebressources/__APPRESS__.css"/>
<script src="/dbwebressources/javascripts/prototype.js"></script>
<script src="/dbwebressources/javascripts/scriptaculous.js"></script>
<script src="/dbwebressources/javascripts/combobox.js"></script>
<script src="/dbwebressources/javascripts/contextmenu.js"></script>
<script src="/dbwebressources/javascripts/livegrid.js"></script>
<script src="/dbwebressources/javascripts/progress.js"></script>
<script src="/dbwebressources/javascripts/border.js"></script>
<script src="/dbwebressources/javascripts/hotkey.js"></script>
<script src="/dbwebressources/javascripts/dbweb_v09.js"></script>
__ADDHTML__

<script language=javascript>
	try{ jQuery.noConflict(); } catch (e) {};
	Event.observe(window, 'load', function() { dbweb=new DBWeb("__APPNAME__","__SESSIONID__","__URI__","__ADDURI__") } );
</script>

</head>

<noscript>Hey dude, turn that JavaScript ON!
</noscript>

</html>
__JSEOF__
}
1;
