# 11.12.05 by dr. boehringer

package DG;

sub dayOfWeek{ my ($self,$date)=@_;
	my $statement='select EXTRACT(DOW FROM DATE \''.$date.'\');';
	return $self->executeSQLStatement($statement)->[0]->[0];
}
sub dateByAddingMinutes{ my ($self, $date, $minutes)=@_;
	my $statement='select timestamp \''.$date.'\' + interval \''.$minutes.' minute\';';
	return $self->executeSQLStatement($statement)->[0]->[0];
}
sub dateByAddingDays{ my ($self, $date, $days)=@_;
	my $statement='select timestamp \''.$date.'\' + interval \''.$days.' day\';';
	return $self->executeSQLStatement($statement)->[0]->[0];
}
