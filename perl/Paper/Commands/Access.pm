package Paper::Commands::Access;

use strict;
use warnings;
use Exporter qw/import/;

use constant ACCESS_LEVELS => {
	ACCESS_NONE => 0,
	ACCESS_VOICE => 1,
	ACCESS_HALFOP => 2,
	ACCESS_OP => 3,
	ACCESS_CHANADMIN => 4,
	ACCESS_BOTADMIN => 5,
	ACCESS_MASTER => 6
};

use constant ACCESS_LEVELS();

our @EXPORT = (keys %{ACCESS_LEVELS()}, 'valid_access_level');

my %level_nums = map { $_ => 1 } values %{ACCESS_LEVELS()};

sub valid_access_level {
	my $level = shift // return undef;
	return exists $level_nums{$level};
}

1;
