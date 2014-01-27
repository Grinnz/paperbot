#!/usr/bin/env perl

use strict;
use warnings;
use POE;
use Paper;

my $homedir = $ENV{'HOME'} // '~';

while (1) {
	my $paper = Paper->new("$homedir/.paperbot/gamesurge", IRC_GAMESURGE);
	
	$paper->init_irc;

	POE::Session->create(
		object_states => [
			$paper => [ qw/_default _start sig_terminate irc_375 irc_372 irc_376
				irc_disconnected irc_ping irc_notice irc_public irc_msg
				irc_invite irc_kick irc_join irc_part irc_quit irc_nick irc_mode
				irc_352 irc_315 irc_311 irc_319 irc_313 irc_301 irc_335
				irc_317 irc_318 irc_330 irc_331 irc_332 irc_333 irc_422 dns_response/
			],
		],
		heap => { irc => $paper->irc }
	);

	POE::Kernel->run;
	
	exit if $paper->is_stopping;
}
