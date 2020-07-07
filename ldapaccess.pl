#!/usr/bin/perl
use Net::LDAP;

sub LDAPChallenge { my ($name, $password)=@_;
	my $ldap = Net::LDAP->new( 'ldap://ldap.xxx.xxx.de' );

	my $msg = $ldap->bind( 'uid='.$name.', ou=people, dc=ukl, dc=uni, dc=de', password => $password);
	return $msg->code==0;
}

sub isAugenklinik { my ($name, $rname, $rname2, $rname3)=@_;
	return 1;
	return 0;
}

sub saveUserAndPasswortToCookie { my ($name, $password)=@_;
	use Apache2::Cookie;
	use Crypt::CBC;
	my $cipher = Crypt::CBC->new(	-key    => '4564A7896456468X4464C87864332',		# super secret key (same as in readUserAndPasswortFromCookie!)
									-cipher => 'Blowfish'
								);
	$password=$cipher->encrypt($password);
	Apache2::Cookie->new($dbweb::apache, name => "login_credentials", value =>{name=>$name, password=>$password },
								-path  => '/',
								-expires => '+1Y'
						)->bake($dbweb::apache);
}

sub readUserAndPasswortFromCookie { 
	use Apache2::Cookie;
	use Crypt::CBC;
	use URI::Escape;
	my $cipher = Crypt::CBC->new(	-key    => '4564A7896456468X4464C87864332',
									-cipher => 'Blowfish'
								);
	my %cookies = Apache2::Cookie->fetch($dbweb::apache);
	my ($name, $password);
	if ( exists $cookies{login_credentials})
	{	my $login=$cookies{login_credentials};
		$password=uri_unescape($1) if $login=~/password&([^&]+)/os;
		$password=$cipher->decrypt($password);
		$name=uri_unescape($1) if $login=~/name&([^&]+)/os;
	}
	return ($name, $password) if($name && $password);
	return undef;
}
