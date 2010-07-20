#!/usr/bin/perl
use Net::LDAP;

sub LDAPChallenge { my ($name, $password)=@_;
	my $ldap = Net::LDAP->new( 'ldap://ldap.ukl.uni-freiburg.de' );
	my $msg = $ldap->bind( 'uid='.$name.', ou=people, dc=ukl, dc=uni-freiburg, dc=de', password => $password);
	return $msg->code==0;
}

sub isAugenklinik { my ($name,$rname)=@_;
	my $ldap = Net::LDAP->new( 'ldap://ldap.ukl.uni-freiburg.de' );
	my $msg = $ldap->search(base=>'ou=people, dc=ukl, dc=uni-freiburg, dc=de', filter=>'(uid='.$name.')');
	my $result;
	foreach my  $entry ($msg->entries) { 
		$$rname=$entry->get_value('sn');
		$result .= $entry->get_value('postalAddress'); }
	return 1 if $result=~/Augenheilkunde/o;
	return 0;
}
