package Paper::IRC;

use strict;
use warnings;
use Carp;
use POE;
use HTML::Entities;
use Date::Parse;
use Time::Duration;
use Paper::Commands;
use Exporter qw/import/;

use constant QUEUE_TIMEOUT => 60;

use constant CHANNEL_STATUS_PREFIXES => '-~&@%+';

my %channel_access_map = (
	'' => ACCESS_NONE,
	'+' => ACCESS_VOICE,
	'%' => ACCESS_HALFOP,
	'@' => ACCESS_OP,
	'&' => ACCESS_CHANADMIN,
	'~' => ACCESS_CHANADMIN,
	'-' => ACCESS_CHANADMIN
);

our @EXPORT = qw/irc_375 irc_372 irc_376 irc_disconnected irc_ping irc_notice irc_public irc_msg
	irc_invite irc_kick irc_join irc_part irc_quit irc_nick irc_mode
	irc_352 irc_315 irc_311 irc_319 irc_313 irc_320 irc_301 irc_335
	irc_317 irc_318 irc_331 irc_332 irc_333/;

sub irc_375 { # RPL_MOTDSTART
}

sub irc_372 { # RPL_MOTD
} # really don't want all this crap in the debug output

sub irc_disconnected {
	my $self = $_[OBJECT];
	$self->end_sessions;
}

sub irc_ping {
} # see RPL_MOTD

sub irc_invite {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$channel) = @_[ARG0,ARG1];
	my $inviter = ( split /!/, $who )[0];

	if ($self->state_user($inviter, 'ircop')) {
		$self->print_debug("Invited to $channel by $inviter. Joining...");
		$irc->yield(join => $channel);
	} elsif (!$self->queue_invite_exists($inviter)) {
		$self->print_debug("Invited to $channel by $inviter. Checking access...");
		$irc->yield(whois => $inviter);
		$self->queue_invite($inviter, $channel);
	}
}

sub irc_kick {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$channel,$kickee) = @_[ARG0 .. ARG2];
	my $kicker = ( split /!/, $who )[0];
	$self->print_debug("$kickee was kicked from $channel by $kicker.");

	#record_seen($kicker,'kicking someone from ',$channel);
	#record_seen($kickee,'getting kicked from ',$channel);
	
	$self->state_channel_user($channel, $kickee, undef);
	
	if (lc $kickee eq lc $self->nick) {
		$self->print_debug("Attempting to rejoin $channel...");
		$irc->yield(join => $channel);
	}
}

sub irc_join {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$channel) = @_[ARG0,ARG1];
	my $user = ( split /!/, $who )[0];
	$self->print_debug("$user has joined $channel.");
	
	$self->state_user($user, 'cached', 0) if $self->state_user_exists($user);

	#record_seen($user,'joining ',$channel);
	
	if (lc $user eq lc $self->nick) {
		$irc->yield(who => $channel);
		$self->state_channel($channel, 'in', 1);
	} else {
		$irc->yield(who => $user);
	}
}

sub irc_part {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$channel) = @_[ARG0,ARG1];
	my $user = ( split /!/, $who )[0];
	$self->print_debug("$user has left $channel.");
	
	#record_seen($user,'leaving ',$channel);
	
	$self->state_channel_user($channel, $user, undef);

	if (lc $user eq lc $self->nick and $self->state_channel_exists($channel)) {
		$self->state_channel_delete($channel);
	}
}

sub irc_quit {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($host,$msg) = @_[ARG0,ARG1];
	my $user = ( split /!/, $host )[0];
	$self->print_debug("$user has quit.");
	
	$self->state_user($user, 'cached', 0) if $self->state_user_exists($user);

	#record_seen($user,'quitting','',$host,$msg);

	$self->state_user_delete_channels($user);
}

sub irc_nick {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$newnick) = @_[ARG0,ARG1];
	my $oldnick = ( split /!/, $who )[0];
	$self->print_debug("$oldnick has changed nick to $newnick.");
	
	#record_seen($oldnick,"changing nick to $newnick",'');
	#record_seen($newnick,"changing nick from $oldnick",'');

	#copy_nicks($newnick,$oldnick);
	#unless (grep {lc $newnick eq lc $_} @{$seen->{lc $oldnick}{nicks}}) {
	#push @{$seen->{lc $oldnick}{nicks}}, $newnick;
	#}
	#$seen->{lc $newnick}{nicks} = $seen->{lc $oldnick}{nicks};
	
	$self->state_user_copy($oldnick => $newnick);
	$self->state_user($newnick, 'cached', 0) if $self->state_user_exists($newnick);
}

sub irc_mode {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$what,$mode,@params) = @_[ARG0 .. $#_];
	my $changer = ( split /!/, $who )[0];
	if ($what =~ /^\#/) {
		my $channel = $what;
		#@params = @params[1..($#params-1)];
		
		$self->print_debug("$changer has changed the mode of $channel to $mode @params");
		#record_seen($changer,"changing the mode to $mode @params in ",$channel);
		
		if (@params and $mode =~ /[qaohvbe]/) {
			if ($mode =~ /[qaohv]/) {
				foreach (@params) {
					unless (lc $_ eq lc $self->nick) {
						$irc->yield(quote => join ' ',('who','+cn',$channel,$_));
					}
				}
			}
		}
	}
	else {
		my $user = $what;
		$self->print_debug("$changer has changed ${user}'s mode to $mode @params");
	}
}

sub irc_331 { # RPL_NOTOPIC
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $channel = $_[ARG2]->[0];
	
	if ($self->queue_topic_exists($channel)) {
		$irc->yield(privmsg => $channel => "Channel $channel has no topic.");
		$self->queue_topic_delete($channel);
	}
}

sub irc_332 { # RPL_TOPIC
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $channel = $_[ARG2]->[0];
	my $topic = $_[ARG2]->[1];
	if ($self->queue_topic_exists($channel) and $self->queue_topic_step($channel) eq 'ask') {
		$irc->yield(privmsg => $channel => "Topic for $channel: $topic");
		$self->queue_topic_step($channel, 'displayed');
	}
}

sub irc_333 { # topic info
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $channel = $_[ARG2]->[0];
	my $author = $_[ARG2]->[1];
	my $time = $_[ARG2]->[2];
	if ($self->queue_topic_exists($channel) and $self->queue_topic_step($channel) eq 'displayed') {
		my $timestring = gmtime($time);
		$irc->yield(privmsg => $channel => "Set by $author on $timestring GMT");
		$self->queue_topic_delete($channel);
	}
}

sub irc_352 { # RPL_WHOREPLY
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $channel = $_[ARG2]->[0];
	my $user = $_[ARG2]->[1];
	my $host = $_[ARG2]->[2];
	my $nick = $_[ARG2]->[4];
	my $state = $_[ARG2]->[5];
	my $name = $_[ARG2]->[6];
	$name =~ s/^\d+ //;
	$self->print_debug("Received who response: $nick");
	
	my ($away, $reg, $bot, $ircop, $status);
	my $prefixes = CHANNEL_STATUS_PREFIXES;
	if ($state =~ /([HG])(r?)(B?)(\*?)([$prefixes]?)/) {
		$away = ($1 eq 'G') ? 1 : 0;
		$reg = $2 ? 1 : 0;
		$bot = $3 ? 1 : 0;
		$ircop = $4 ? 1 : 0;
		$status = $5 ? channel_access_code($5) : 0;
	}
	
	$self->state_user($nick, 'user', $user);
	$self->state_user($nick, 'host', $host);
	$self->state_user($nick, 'name', $name);
	$self->state_user($nick, 'away', $away);
	$self->state_user($nick, 'reg', $reg);
	$self->state_user($nick, 'bot', $bot);
	$self->state_user($nick, 'ircop', $ircop);
	$self->state_channel_user($channel, $nick, $status);
}

sub irc_315 { # RPL_ENDOFWHO
}

sub irc_notice {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$where,$msg) = @_[ARG0 .. ARG2];
	my $sender = ( split /!/, $who )[0];
	my $receiver = $where->[0];
	$self->print_echo("$sender sent a notice to $receiver: $msg") if $self->config_var('echo');

	if ($receiver =~ /^#/) {
		#record_seen($sender,'sending a notice to ',$receiver);
	} elsif (lc $receiver eq lc $self->nick) {
		if (lc $sender eq 'chanserv') {
			my ($ident, $nick, $channel, $authed);
			if ($msg =~ /^([[:graph:]]+) - ([[:graph:]]+)/) {
				$ident = $1;
				$nick = $self->state_ident($ident);
				if ($self->queue_invite_exists($nick)) {
					if (lc $2 eq 'admin' or lc $2 eq 'owner') {
						$authed = 1;
						$self->print_debug("$nick ($ident) has $2 channel access.");
					} else {
						$self->print_debug("$nick ($ident) does not have admin channel access.");
						$irc->yield(notice => $nick => "You must have admin access in the channel to invite me.");
					}
				}
			} elsif ($msg =~ /^([[:graph:]]+) is not on access list for ([[:graph:]]+)$/) {
				$ident = $1;
				$nick = $self->state_ident($ident);
				$channel = $2;
				if ($self->queue_invite_exists($nick)) {
					$self->print_debug("$nick ($ident) does not have access in $channel");
					$irc->yield(notice => $nick => "You must have admin access in $channel to invite me.");
				}
			} elsif ($msg =~ /^Channel ([[:graph:]]+) is not registered.$/) {
				$channel = $1;
				$self->print_debug("Invite attempted to unregistered channel $channel");
			}
			if ($authed and defined $nick and $self->queue_invite_exists($nick)) {
				$channel = $self->queue_invite_channel($nick);
				$self->print_debug("Joining $channel as requested...");
				$irc->yield(join => $channel);
				$irc->yield(notice => $nick => "If you would like me to stay in $channel, type ~stay after I have joined.");
			}
			$self->queue_invite_delete($nick) if defined $nick;
		}
	}
}

sub irc_public {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$where,$msg) = @_[ARG0 .. ARG2];
	my $sender = ( split /!/, $who )[0];
	my $channel = $where->[0];
	$self->print_echo("$sender said something on $channel: $msg");

	if ($self->state_channel($channel, 'nazi')) {
		$self->chan_nazi($irc,$channel,$msg);
	}
	
	if ($self->config_var('catchtube') and strip_formatting($msg) !~ /^~youtubeinfo\s/
			and strip_formatting($msg) =~ m!(https?://)?(www\.)?youtube\.com/watch\?([[:graph:]]+?&)?v=([[:alnum:]\-_]+)[^#\s]*(#[[:graph:]]+)?!) {
		my $video_id = $4;
		my $hash = $5;
		$self->print_debug("Caught youtube URL: $video_id");
		my $video = $self->search_youtube_id($video_id);
		unless (defined $video) {
			$video_id =~ s/^-//;
			$self->print_debug("Video ID not found. Searching youtube for $video_id");	
			my $results = $self->search_youtube($video_id, 1);
			if (defined $results and $results->[0]->title) {
				$video = $results->[0];
			}
		}
		if (defined $video) {
			$self->print_debug("Resolved video ID: " . $video->title . "");
			my $b_code = chr(2);
			my @links = grep { $_->rel eq 'alternate' } $video->link;
			my $href = @links ? $links[0]->href : $video->link->href;
			$href .= $hash if defined $hash;
			$irc->yield(privmsg => $channel => "YouTube Video linked by $sender: " . $b_code .
				Paper::strip_wide($video->title) . $b_code . " | uploaded by " . $video->author->name . " | " . $href);
		} else {
			$self->print_debug("Cannot find video: $video_id");
			$irc->yield(privmsg => $channel => "YouTube Video linked by $sender: Video does not exist or has not yet been indexed");
		}
	}
	
	if ($self->config_var('catchtweet') and strip_formatting($msg) =~ m!(https?://)?(www\.)?twitter\.com/([^/]+?)/status/(\d+)!) {
		my $tweet_id = $4;
		$self->print_debug("Caught tweet: $tweet_id");
		my $tweet = $self->search_twitter_id($tweet_id);
		if (defined $tweet) {
			$self->print_debug("Resolved tweet by " . $tweet->{'user'}{'screen_name'} . ": " . $tweet->{'text'});
			my $username = $tweet->{'user'}{'screen_name'};
			my $content = $tweet->{'text'};
			unless (defined $username and defined $content) {
				$irc->yield(privmsg => $channel => "Invalid tweet information");
				return;
			}
			
			my $base_url = "https://twitter.com";
			my $id = $tweet->{'id'};
			my $url = "$base_url/$username/status/$id";
			
			my $b_code = chr(2);

			my $name = $tweet->{'user'}{'name'} // $username;
			my $in_reply_to_id = $tweet->{'in_reply_to_status_id'};
			my $in_reply_to_user = $tweet->{'in_reply_to_screen_name'};
			my $in_reply_to = '';
			if (defined $in_reply_to_id) {
				$in_reply_to = " in reply to $b_code\@$in_reply_to_user$b_code tweet \#$in_reply_to_id";
			}
		
			$content = $self->parse_tweet_text($content);
			my $ago = ago(time-(str2time($tweet->{'created_at'})//time));
			$irc->yield(privmsg => $channel => "Tweet linked by $sender: Posted by $name ($b_code\@$username$b_code) $ago$in_reply_to: $content [ $url ]");
		} else {
			$self->print_debug("Cannot find tweet: $tweet_id");
			$irc->yield(privmsg => $channel => "Tweet linked by $sender: Not found");
		}
	}

	#record_seen($sender,'talking in ',$channel);

	if (strip_formatting($msg) =~ /^\~([[:graph:]]+)/) {
		my $cmds = $self->command_exists(lc $1);
		if (@$cmds) {
			if (scalar @$cmds == 1) {
				my $cmd = lc $cmds->[0];
				my $args = '';
				if ($msg =~ /^[[:graph:][:cntrl:]]+ +(.*?)$/) { $args = $1; }
				$args = strip_formatting($args) if $self->command_strip($cmd);
				$self->print_debug("Command: [$channel] ($sender) $cmd $args");
				$self->parse_cmd($irc,$sender,$channel,$cmd,$args);
			} else {
				$self->print_debug("Command $1 is ambiguous");
				my $cmds_str = join ' ', @$cmds;
				$irc->yield(privmsg => ($channel || $sender) => "Command \"$1\" is ambiguous. Did you mean: $cmds_str");
			}
		}
	}
}

sub irc_msg {
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my ($who,$where,$msg) = @_[ARG0 .. ARG2];
	my $sender = ( split /!/, $who )[0];
	$self->print_echo("$sender sent me a private message: $msg");
	
	if (strip_formatting($msg) =~ /^\~?([[:graph:]]+)/) {
		my $cmds = $self->command_exists(lc $1);
		if (@$cmds) {
			if (scalar @$cmds == 1) {
				my $cmd = lc $cmds->[0];
				my $args = '';
				if ($msg =~ /^[[:graph:][:cntrl:]]+ +(.*)$/) { $args = $1; }
				$args = strip_formatting($args) if $self->command_strip($cmd);
				$self->print_debug("Command: [privmsg] ($sender) $cmd $args");
				$self->parse_cmd($irc,$sender,0,$cmd,$args);
			} else {
				$self->print_debug("Command [privmsg] $1 is ambiguous");
				my $cmds_str = join ' ', @$cmds;
				$irc->yield(privmsg => $sender => "Command \"$1\" is ambiguous. Did you mean: $cmds_str");
			}
		}
		else {
			$irc->yield(privmsg => $sender,"What?");
		}
	}
}

sub irc_whois {
}

sub irc_311 { # RPL_WHOISUSER
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $user = $_[ARG2]->[1];
	my $host = $_[ARG2]->[2];
	my $name = $_[ARG2]->[4];

	$self->print_debug("Set host of $nick to $nick!$user\@$host");
	$self->state_user($nick, 'user', $user);
	$self->state_user($nick, 'host', $host);
	$self->state_user($nick, 'name', $name);
	$self->state_user($nick, 'reg', 0);
	$self->state_user($nick, 'ident', undef);
	$self->state_user($nick, 'away', 0);
	$self->state_user($nick, 'awaymsg', '');
	$self->state_user($nick, 'ircop', 0);
	$self->state_user($nick, 'ircopmsg', '');
	$self->state_user($nick, 'bot', 0);
	$self->state_user($nick, 'idle', 0);
	$self->state_user($nick, 'signon', 0);
}

sub irc_319 { # RPL_WHOISCHANNELS
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $channels = $_[ARG2]->[1];

	$self->print_debug("$nick is in these channels: $channels");
	
	my $prefixes = CHANNEL_STATUS_PREFIXES;
	foreach my $channel (split /\s+/, $channels) {
		if ($channel =~ /^([$prefixes]?)(\#[[:graph:]]+)$/) {
			my ($prefix, $name) = ($1, $2);
			if ($prefix) {
				#$self->print_debug("Set access of $nick in $name to $prefix");
				$self->state_channel_user($name, $nick, channel_access_code($prefix));
			} else {
				#$self->print_debug("Set access of $nick in $name to none");
				$self->state_channel_user($name, $nick, ACCESS_NONE);
			}
		}
	}
}

sub irc_301 { # RPL_AWAY
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $awaymsg = $_[ARG2]->[1];
	
	$self->print_debug("$nick is away: $awaymsg");
	$self->state_user($nick, 'away', 1);
	$self->state_user($nick, 'awaymsg', $awaymsg);
}

sub irc_313 { # RPL_WHOISOPERATOR
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $ircopmsg = $_[ARG2]->[1];
	
	$self->print_debug("$nick is an IRCop: $ircopmsg");
	$self->state_user($nick, 'ircop', 1);
	$self->state_user($nick, 'ircopmsg', $ircopmsg);
}

sub irc_335 { # whois bot string
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	
	$self->print_debug("$nick is a bot");
	$self->state_user($nick, 'bot', 1);
}

sub irc_317 { # RPL_WHOISIDLE
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];
	my $idle = $_[ARG2]->[1];
	my $signon = $_[ARG2]->[2];

	$self->print_debug("$nick has been idle for $idle seconds");
	$self->state_user($nick, 'idle', $idle);
	$self->state_user($nick, 'signon', $signon);
}

sub irc_318 { # RPL_ENDOFWHOIS
	my $self = $_[OBJECT];
	my $irc = $_[SENDER]->get_heap();
	my $nick = $_[ARG2]->[0];

	if ($self->state_user_exists($nick)) {
		$self->state_user($nick, 'cached', 1);
		if ($self->state_user($nick, 'ident')) {
			#$seen->{lc $nick} = { nicks => [ $nick ] } unless exists $seen->{lc $nick};
			#find_nicks($nick);
		}
		if ($self->queue_cmd_exists($nick)) {
			my $channel = $self->queue_cmd_channel($nick);
			my $command = $self->queue_cmd_command($nick);
			my $args = $self->queue_cmd_args($nick);
			$self->queue_cmd_delete($nick);
			$self->parse_cmd($irc,$nick,$channel,$command,$args,1);
		}
		if ($self->queue_whois_exists($nick)) {
			my $channel = $self->queue_whois_channel($nick);
			my $type = $self->queue_whois_type($nick);
			my $sender = $self->queue_whois_sender($nick);
			my $args = $self->queue_whois_args($nick) // $nick;
			$self->queue_whois_delete($nick);
			$self->say_userinfo($irc,$type,$sender,$channel,$args);
		}
		if ($self->queue_invite_exists($nick) and $self->queue_invite_step($nick) eq 'whois') {
			if ($self->state_user($nick, 'ident')) {
				my $ident = $self->state_user($nick, 'ident');
				my $channel = $self->queue_invite_channel($nick);
				$self->print_debug("$nick is logged in as $ident");
				$irc->yield(privmsg => 'ChanServ' => "access $channel query $ident");
				$self->queue_invite_step($nick, 'access');
			} else {
				$self->print_debug("$nick is not logged in");
				$irc->yield(privmsg => $nick => "You must be logged in to invite me.");
				$self->queue_invite_delete($nick);
			}
		}
	}
	else {
		if ($self->queue_cmd_exists($nick)) {
			my $channel = $self->queue_cmd_channel($nick);
			$irc->yield(privmsg => $channel => "Error: $nick does not appear to exist.");
			$self->queue_cmd_delete($nick);
		}
		if ($self->queue_whois_exists($nick)) {
			my $type = $self->queue_whois_type($nick);
			my $channel = $self->queue_whois_channel($nick);
			my $sender = $self->queue_whois_sender($nick);
			my $args = $self->queue_whois_args($nick) // $nick;
			if ($type eq 'dns') {
				$self->say_userinfo($irc, 'dns', $sender, $channel, $args);
			} elsif ($type eq 'wolframalpha') {
				$self->say_userinfo($irc, 'wolframalpha', $sender, $channel, $args);
			} else {
				$irc->yield(privmsg => $channel, "Error: No such user ($nick)");
			}
			$self->queue_whois_delete($nick);
		}
		if ($self->queue_invite_exists($nick) and $self->queue_invite_step($nick) eq 'whois') {
			$self->print_debug("WTF");
			$self->queue_invite_delete($nick);
		}
	}
}

# === Module functions ===

sub channel_access_code {
	my $prefix = shift;
	croak "Invalid function parameters" unless defined $prefix;
	
	return undef unless exists $channel_access_map{$prefix};
	return $channel_access_map{$prefix};
}

sub strip_formatting {
    # strip ALL user formatting from IRC input (color, bold, underline, plaintext marker)
    my $arg = shift;
    my $c_code = chr(3);      # how colors are read by us
    my $u_code = chr(31);     # how underlines are read
    my $b_code = chr(2);      # how bold is read
    my $p_code = chr(15);     # how plaintext is read
    $arg =~ s/(($c_code(\d\d?(\,\d\d?)?)?)|$u_code|$b_code|$p_code)//g;
    return $arg;
}

1;

