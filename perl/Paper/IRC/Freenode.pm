package Paper::IRC::Freenode;

use strict;
use warnings;
use Carp;
use POE;
use Paper::Commands;
use Exporter qw/import/;

our @EXPORT = qw/irc_376 irc_422 irc_330/;

sub irc_376 { # RPL_ENDOFMOTD
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	$self->print_debug("Connected. Identifying with NickServ...");
	my $nick = $self->nick;
	my $password = $self->config_var('password');
	my $awaymsg = $self->config_var('awaymsg');
	$irc->yield( privmsg => 'NickServ' => "identify $nick $password" );
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
	$irc->yield( privmsg => 'NickServ' => "identify $nick $password" );
	$irc->yield( mode => "$nick +B" );
	$irc->yield( away => $awaymsg );
	$irc->yield( whois => $nick );
	$self->autojoin($irc);
}

sub irc_330 { # RPL_WHOISACCOUNT
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $lia = $_[ARG2]->[1];
	
	$self->state_user($nick, 'reg', 1);
	$self->print_debug("Set identity of $nick to $lia");
	$self->state_user($nick, 'ident', $lia);
	$self->state_ident($lia, $nick);
}

1;
