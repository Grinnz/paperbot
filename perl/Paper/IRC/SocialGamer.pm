package Paper::IRC::SocialGamer;

use strict;
use warnings;
use Carp;
use POE;
use Paper::Commands;
use Exporter qw/import/;

our @EXPORT = qw/irc_376 irc_422 irc_320/;

sub irc_376 { # RPL_ENDOFMOTD
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	$self->print_debug("Connected. Identifying with NickServ...");
	my $nick = $self->nick;
	my $password = $self->config_var('password');
	my $awaymsg = $self->config_var('awaymsg');
	$irc->yield( privmsg => 'NickServ' => "identify Paper $password" );
	$irc->yield( mode => "$nick +B" );
	$irc->yield( away => $awaymsg );
	$irc->yield( whois => $nick );
	$self->autojoin($irc);
}

sub irc_422 { # ERR_NOMOTD
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	$self->print_debug("Connected. Identifying with NickServ...");
	my $nick = $self->nick;
	my $password = $self->config_var('password');
	my $awaymsg = $self->config_var('awaymsg');
	$irc->yield( privmsg => 'NickServ' => "identify Paper $password" );
	$irc->yield( mode => "$nick +B" );
	$irc->yield( away => $awaymsg );
	$irc->yield( whois => $nick );
	$self->autojoin($irc);
}

sub irc_320 { # RPL_WHOISIDENTIFIED
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $lia = $_[ARG2]->[1];
	
	$self->state_user($nick, 'reg', 1);
	if ($lia =~ /is logged in as ([[:graph:]]+)/) {
		$self->print_debug("Set identity of $nick to $1");
		$self->state_user($nick, 'ident', $1);
		$self->state_ident($1, $nick);
	}
	else { $self->print_debug("Invalid ident string for $nick: $lia"); }
}

1;
