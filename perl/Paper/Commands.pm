package Paper::Commands;

use strict;
use warnings;
use Carp;
use POE;
use Exporter qw/import/;
use HTML::Entities;
use Date::Parse;
use Time::Duration;
use Scalar::Util qw/looks_like_number/;
use Math::Complex;
use Math::Trig;
use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use Encode qw/decode/;
use LWP::Simple;

use constant MAX_FORECAST_DAYS => 3;

use constant {
	ACCESS_NONE => 0,
	ACCESS_VOICE => 1,
	ACCESS_HALFOP => 2,
	ACCESS_OP => 3,
	ACCESS_CHANADMIN => 4,
	ACCESS_BOTADMIN => 5,
	ACCESS_MASTER => 6
};

our @EXPORT = qw/cmds_substr_index command_exists command_strip parse_cmd check_access cmd_queue_info say_userinfo do_conversion do_wolframalpha_query
	ACCESS_NONE ACCESS_VOICE ACCESS_HALFOP ACCESS_OP ACCESS_CHANADMIN ACCESS_BOTADMIN ACCESS_MASTER/;

my %userinfo = (
	'user' => \&say_whois,
	'away' => \&say_away,
	'access' => \&say_access,
	'idle' => \&say_idle,
	'dns' => \&say_dnshost,
	'locate' => \&say_locate,
	'weather' => \&say_weather,
	'forecast' => \&say_forecast,
	'wolframalpha' => \&say_wolframalpha
);

my %command = (
	'enable' => { func => 'cmd_enable', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'disable' => { func => 'cmd_disable', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'fuckoff' => { func => 'cmd_fuckoff', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'leave' => { func => 'cmd_leave', access => ACCESS_CHANADMIN, on => 1, strip => 0 },
	'quit' => { func => 'cmd_quit', access => ACCESS_MASTER, on => 1, strip => 0 },
	'restart' => { func => 'cmd_restart', access => ACCESS_MASTER, on => 1, strip => 0 },
	'say' => { func => 'cmd_say', access => ACCESS_VOICE, on => 1, strip => 0 },
	'me' => { func => 'cmd_me', access => ACCESS_VOICE, on => 1, strip => 0 },
	'ping' => { func => 'cmd_ping', access => ACCESS_VOICE, on => 1, strip => 0 },
	'ding' => { func => 'cmd_ding', access => ACCESS_VOICE, on => 1, strip => 0 },
	'version' => { func => 'cmd_version', access => ACCESS_NONE, on => 1, strip => 0 },
	'sysinfo' => { func => 'cmd_sysinfo', access => ACCESS_OP, on => 1, strip => 0 },
	'addquote' => { func => 'cmd_addquote', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'delquote' => { func => 'cmd_delquote', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'quote' => { func => 'cmd_quote', access => ACCESS_NONE, on => 1, strip => 1 },
	'quoten' => { func => 'cmd_quoten', access => ACCESS_NONE, on => 1, strip => 1 },
	'listquotes' => { func => 'cmd_listquotes', access => ACCESS_MASTER, on => 0, strip => 0 },
	'join' => { func => 'cmd_join', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'help' => { func => 'cmd_help', access => ACCESS_NONE, on => 1, strip => 0 },
	'conf' => { func => 'cmd_conf', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'seen' => { func => 'cmd_seen', access => ACCESS_VOICE, on => 0, strip => 1 },
	'whois' => { func => 'cmd_whois', access => ACCESS_VOICE, on => 1, strip => 1 },
	'whoami' => { func => 'cmd_whoami', access => ACCESS_VOICE, on => 1, strip => 0 },
	'topic' => { func => 'cmd_topic', access => ACCESS_VOICE, on => 1, strip => 0 },
	'clear' => { func => 'cmd_clear', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'adduser' => { func => 'cmd_adduser', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'deluser' => { func => 'cmd_deluser', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'away' => { func => 'cmd_away', access => ACCESS_VOICE, on => 1, strip => 1 },
	'access' => { func => 'cmd_access', access => ACCESS_VOICE, on => 1, strip => 1 },
	'dns' => { func => 'cmd_dns', access => ACCESS_VOICE, on => 1, strip => 1 },
	'rdns' => { func => 'cmd_rdns', access => ACCESS_VOICE, on => 1, strip => 1 },
	'idle' => { func => 'cmd_idle', access => ACCESS_VOICE, on => 1, strip => 1 },
	'nicks' => { func => 'cmd_nicks', access => ACCESS_VOICE, on => 0, strip => 1 },
	'addchan' => { func => 'cmd_addchan', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'delchan' => { func => 'cmd_delchan', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'stay' => { func => 'cmd_stay', access => ACCESS_CHANADMIN, on => 1, strip => 0 },
	'listchans' => { func => 'cmd_listchans', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'google' => { func => 'cmd_google', access => ACCESS_NONE, on => 1, strip => 1 },
	'spell' => { func => 'cmd_spell', access => ACCESS_NONE, on => 1, strip => 1 },
	'define' => { func => 'cmd_define', access => ACCESS_VOICE, on => 0, strip => 1 },
	'spellmode' => { func => 'cmd_spellmode', access => ACCESS_MASTER, on => 1, strip => 1 },
	'youtube' => { func => 'cmd_youtube', access => ACCESS_NONE, on => 1, strip => 1 },
	'youtubeinfo' => { func => 'cmd_youtubeinfo', access => ACCESS_NONE, on => 1, strip => 1 },
	'calc' => { func => 'cmd_calc', access => ACCESS_VOICE, on => 1, strip => 0 },
	'save' => { func => 'cmd_save', access => ACCESS_MASTER, on => 1, strip => 0 },
	'reload' => { func => 'cmd_reload', access => ACCESS_MASTER, on => 1, strip => 0 },
	'joinall' => { func => 'cmd_joinall', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'todo' => { func => 'cmd_todo', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'done' => { func => 'cmd_done', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'addpath' => { func => 'cmd_addpath', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'delpath' => { func => 'cmd_delpath', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'updatepath' => { func => 'cmd_updatepath', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'path' => { func => 'cmd_path', access => ACCESS_VOICE, on => 1, strip => 1 },
	'voxpath' => { func => 'cmd_voxpath', access => ACCESS_VOICE, on => 1, strip => 1 },
	'drumpath' => { func => 'cmd_drumpath', access => ACCESS_VOICE, on => 1, strip => 1 },
	'setsong' => { func => 'cmd_setsong', access => ACCESS_VOICE, on => 1, strip => 1 },
	'song' => { func => 'cmd_song', access => ACCESS_NONE, on => 1, strip => 1 },
	'fight' => { func => 'cmd_fight', access => ACCESS_VOICE, on => 1, strip => 1 },
	'earmuffs' => { func => 'cmd_earmuffs', access => ACCESS_BOTADMIN, on => 1, strip => 1 },
	'genhelp' => { func => 'cmd_genhelp', access => ACCESS_BOTADMIN, on => 1, strip => 0 },
	'uptime' => { func => 'cmd_uptime', access => ACCESS_VOICE, on => 1, strip => 0 },
	'xkcd' => { func => 'cmd_xkcd', access => ACCESS_VOICE, on => 1, strip => 1 },
	'weather' => { func => 'cmd_weather', access => ACCESS_NONE, on => 1, strip => 1 },
	'forecast' => { func => 'cmd_forecast', access => ACCESS_NONE, on => 1, strip => 1 },
	'convert' => { func => 'cmd_convert', access => ACCESS_NONE, on => 1, strip => 1 },
	'locate' => { func => 'cmd_locate', access => ACCESS_VOICE, on => 1, strip => 1 },
	'wiki' => { func => 'cmd_wiki', access => ACCESS_NONE, on => 1, strip => 1 },
	'translate' => { func => 'cmd_translate', access => ACCESS_NONE, on => 1, strip => 1 },
	'speak' => { func => 'cmd_speak', access => ACCESS_VOICE, on => 1, strip => 1 },
	'twitter' => { func => 'cmd_twitter', access => ACCESS_NONE, on => 1, strip => 1 },
	'wolframalpha' => { func => 'cmd_wolframalpha', access => ACCESS_NONE, on => 1, strip => 1 }
);

sub cmds_structure {
	return \%command;
}

sub cmds_substr_index {
	my $self = shift;
	
	my $substr_cache = $self->{'cache'}{'commands'}{'substrs'};
	
	unless (defined $substr_cache) {
		my @names = sort keys %command;
		foreach my $name (@names) {
			foreach my $l (1..(length $name)) {
				my $substr = lc substr $name, 0, $l;
				next if exists $command{$substr} and $name ne $substr;
				$substr_cache->{$substr} //= [];
				push @{$substr_cache->{$substr}}, $name;
			}
		}
	}
		
	return $substr_cache;
}

# *************************
# Printing info after whois
# *************************

sub say_userinfo {
	my $self = shift;
	my ($irc,$type,$sender,$channel,$args) = @_;
	return undef unless exists $userinfo{$type};
	my $sub = $userinfo{$type};
	return $self->$sub($irc,$sender,$channel,$args);
}

sub say_whois {
	my $self = shift;
	my ($irc,$sender,$channel,$nick) = @_;
	$channel = $sender unless $channel;
	if ($self->state_user_exists($nick)) {
		my $user = $self->state_user($nick, 'user');
		my $host = $self->state_user($nick, 'host');
		my $away = '';
		if ($self->state_user($nick, 'away')) { $away = ' [away]'; }
		if ($self->state_user($nick, 'reg')) {
			my $ident = $self->state_user($nick, 'ident');
			if ($ident eq '' or lc $nick eq lc $ident) {
				$irc->yield(privmsg => $channel => "$nick$away ($user\@$host) is logged in.");
			}
			else {
				$irc->yield(privmsg => $channel => "$nick$away ($user\@$host) is logged in as $ident.");
			}
		}
		else {
			$irc->yield(privmsg => $channel => "$nick$away ($user\@$host) does not appear to be logged in.");
		}
		if ($self->state_user($nick, 'ircop')) {
			my $ircopmsg = $self->state_user($nick, 'ircopmsg');
			$irc->yield(privmsg => $channel => "$nick $ircopmsg");
		}
		if ($self->state_user($nick, 'bot')) {
			my $name = $self->state_user($nick, 'name');
			$irc->yield(privmsg => $channel => "$nick is a bot: $name");
		}
	}
	else {
		$irc->yield(privmsg => $channel => "No data for user $nick.");
	}
}

sub say_away {
	my $self = shift;
	my ($irc,$sender,$channel,$nick) = @_;
	$channel = $sender unless $channel;
	if ($self->state_user_exists($nick)) {
		if ($self->state_user($nick, 'away')) {
			my $awaymsg = $self->state_user($nick, 'awaymsg');
			$irc->yield(privmsg => $channel => "$nick is away: $awaymsg");
		}
		else { $irc->yield(privmsg => $channel => "$nick is not away."); }
	}
	else { $irc->yield(privmsg => $channel => "No data for user $nick."); }
}

sub say_access {
	my $self = shift;
	my ($irc,$sender,$channel,$nick) = @_;
	$channel = $sender unless $channel;
	$nick = $sender unless $nick;
	if ($self->state_user_exists($nick)) {
		my $intaccess = 'no';
		my $ident = $self->state_user($nick, 'ident');
		if (lc $ident eq lc $self->config_var('master')) {
			$intaccess = 'master';
		}
		elsif ($self->state_user($nick, 'ircop')) {
			$intaccess = 'ircop';
		}
		elsif (grep { lc $ident eq lc $_ } @{$self->db_var('admins')}) {
			$intaccess = 'admin';
		}
		elsif (grep { lc $ident eq lc $_ } @{$self->db_var('voices')}) {
			$intaccess = 'voice';
		}
	
		my $chanaccess = 'no';
		my $status = $self->state_channel_user($channel, $nick);
		if (defined $status) {
			if ($status == ACCESS_CHANADMIN) {
				$chanaccess = 'admin';
			}
			elsif ($status >= ACCESS_VOICE) {
				$chanaccess = 'voice';
			}
		}
		$irc->yield(privmsg => $channel => "$nick has $chanaccess channel access and $intaccess internal access.");
	}
	else {
		$irc->yield(privmsg => $channel => "No data for user $nick.");
	}
}

sub say_idle {
	my $self = shift;
	my ($irc,$sender,$channel,$nick) = @_;
	$channel = $sender unless $channel;
	if ($self->state_user_exists($nick)) {
		my $away = '';
		if ($self->state_user($nick, 'away')) { $away = ' [away]'; }
		if ($self->state_user($nick, 'signon')) {
			my $idle = duration_exact($self->state_user($nick, 'idle'));
			my $signon = gmtime($self->state_user($nick, 'signon'));
			$irc->yield(privmsg => $channel => "$nick$away has been idle for $idle and signed on at $signon GMT");
		}
		else { $irc->yield(privmsg => $channel => "$nick$away is never idle."); }
	}
	else { $irc->yield(privmsg => $channel => "No data for user $nick."); }
}

sub say_dnshost {
	my $self = shift;
	my ($irc,$sender,$channel,$arg) = @_;
	$channel = $sender unless $channel;
	
	my ($host, $question);
	if ($self->state_user_exists($arg)) {
		$host = $self->state_user($arg, 'host');
		$question = "$arg ($host)";
	} else {
		$host = $arg;
		$question = $arg;
	}
	
	my $type = 'A';
	if (is_ipv4($host) or is_ipv6($host)) {
		$type = 'PTR';
	}

	my $result = $self->resolver->resolve(
		type	=> $type,
		host	=> $host,
		context	=> { irc => $irc, question => $question, channel => $channel, sender => $sender },
		event	=> 'dns_response',
	);
	if (defined $result) {
		my @args;
		$args[ARG0] = $result;
		splice @args, 0, 1;
		$self->dns_response(@args);
	}
}

sub say_locate {
	my $self = shift;
	my ($irc,$sender,$channel,$arg) = @_;
	$channel = $sender unless $channel;
	
	my ($host, $question);
	if ($self->state_user_exists($arg)) {
		$host = $self->state_user($arg, 'host');
		$question = "$arg ($host)";
	} else {
		$host = $arg;
		$question = $arg;
	}
	
	my $result = $self->resolver->resolve(
		type	=> 'A',
		host	=> $host,
		context	=> { irc => $irc, question => $question, channel => $channel, sender => $sender, action => 'locate' },
		event => 'dns_response',
	);
	if (defined $result) {
		my @args;
		$args[ARG0] = $result;
		splice @args, 0, 1;
		$self->dns_response(@args);
	}
}

sub say_weather {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $weather;
	my $location = $self->search_wunderground_location($args);
	if (defined $location) {
		$weather = $self->search_wunderground_weather($location);
	}
	
	if (defined $weather) {
		my $location = $weather->{'location'} // $weather->{'current_observation'}{'display_location'};
		my $location_str = "";
		if (defined $location) {
			my $city = $location->{'city'};
			my $state = $location->{'state'};
			my $zip = $location->{'zip'};
			my $country = $location->{'country_name'};
			
			$location_str = $city // "";
			$location_str .= ", $state" if defined $state and length $state;
			$location_str .= ", $country" if defined $country and length $country;
			$location_str .= " ($zip)" if defined $zip and length $zip and $zip ne '00000';
		}
		
		my @weather_strings;
		
		my $current = $weather->{'current_observation'} // {};
		
		my $condition = $current->{'weather'};
		if (defined $condition) {
			push @weather_strings, $condition;
		}
		
		my $temp_f = $current->{'temp_f'};
		my $temp_c = $current->{'temp_c'};
		if (defined $temp_f or defined $temp_c) {
			my $deg = chr(0xb0);
			my $temp_str = "$temp_f${deg}F / $temp_c${deg}C";
			push @weather_strings, $temp_str;
		}
		
		my $feelslike_f = $current->{'feelslike_f'};
		my $feelslike_c = $current->{'feelslike_c'};
		if (defined $feelslike_f or defined $feelslike_c) {
			my $deg = chr(0xb0);
			my $feelslike_str = "Feels like $feelslike_f${deg}F / $feelslike_c${deg}C";
			push @weather_strings, $feelslike_str;
		}
		
		my $precip_in = $current->{'precip_today_in'};
		if (defined $precip_in) {
			push @weather_strings, "Precipitation $precip_in\"" if looks_like_number($precip_in) and $precip_in > 0;
		}
		
		my $wind_speed = $current->{'wind_mph'};
		my $wind_direction = $current->{'wind_dir'};
		if (defined $wind_speed) {
			my $wind = "Wind ${wind_speed}mph";
			$wind = "$wind $wind_direction" if defined $wind_direction;
			push @weather_strings, $wind if looks_like_number($wind_speed) and $wind_speed > 0;
		}
		
		my $b_code = chr(2); # how bold is read
		my $weather_str = "Current weather at $b_code$location_str$b_code: " . join '; ', @weather_strings;
		
		$irc->yield(privmsg => $channel => $weather_str);
	} else {
		$irc->yield(privmsg => $channel => "Could not find weather for $args");
	}
}

sub say_forecast {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $loc = $args;
	my $max_days = MAX_FORECAST_DAYS;
	if ($args =~ /^(.+)\s+(\d+)$/) {
		$loc = $1;
		$max_days = $2;
	}
	
	my $weather;
	my $location = $self->search_wunderground_location($loc);
	if (defined $location) {
		$weather = $self->search_wunderground_weather($location);
	}
	
	if (defined $weather) {
		my $location_str = "";
		my $location = $weather->{'location'};
		if (defined $location) {
			my $city = $location->{'city'};
			my $state = $location->{'state'};
			my $zip = $location->{'zip'};
			my $country = $location->{'country_name'};
			
			$location_str = $city // "";
			$location_str .= ", $state" if defined $state and length $state;
			$location_str .= ", $country" if defined $country and length $country;
			$location_str .= " ($zip)" if defined $zip and length $zip and $zip ne '00000';
		}
		
		my @forecast_strings;
		
		my $forecastdays = $weather->{'forecast'}{'simpleforecast'}{'forecastday'};
		
		$max_days = @$forecastdays if $max_days > @$forecastdays;
		foreach my $i (1..$max_days) {
			my $day = $forecastdays->[$i-1];
			next unless defined $day;
			
			my $day_name = $day->{'date'}{'weekday'} // "";
			
			my @day_strings;
			my $conditions = $day->{'conditions'};
			if (defined $conditions) {
				push @day_strings, $conditions;
			}
			
			my $high = $day->{'high'};
			if (defined $high) {
				my $high_f = $high->{'fahrenheit'};
				my $high_c = $high->{'celsius'};
				
				my $deg = chr(0xb0);
				my $high_str = "High $high_f${deg}F / $high_c${deg}C";
				
				push @day_strings, $high_str;
			}
			
			my $low = $day->{'low'};
			if (defined $low) {
				my $low_f = $low->{'fahrenheit'};
				my $low_c = $low->{'celsius'};
				
				my $deg = chr(0xb0);
				my $low_str = "Low $low_f${deg}F / $low_c${deg}C";
				push @day_strings, $low_str;
			}
			
			my $b_code = chr(2); # how bold is read
			push @forecast_strings, "$b_code$day_name$b_code: " . join(', ', @day_strings);
		}
		
		my $b_code = chr(2); # how bold is read
		my $forecast_str = "Weather forecast at $b_code$location_str$b_code: " . join '; ', @forecast_strings;
		
		$irc->yield(privmsg => $channel => $forecast_str);
	} else {
		$irc->yield(privmsg => $channel => "Could not find forecast for $loc");
	}
}

sub say_wolframalpha {
	my $self = shift;
	my ($irc,$sender,$channel,$query) = @_;
	$channel = $sender unless $channel;
	
	my ($host, $question);
	if ($self->state_user_exists($sender)) {
		$host = $self->state_user($sender, 'host');
		$question = "$sender ($host)";
	} else {
		$host = $sender;
		$question = $sender;
	}
	
	my $result = $self->resolver->resolve(
		type	=> 'A',
		host	=> $host,
		context	=> { irc => $irc, question => $question, channel => $channel, sender => $sender, action => 'wolframalpha', query => $query },
		event => 'dns_response',
	);
	if (defined $result) {
		my @args;
		$args[ARG0] = $result;
		splice @args, 0, 1;
		$self->dns_response(@args);
	}
}

# **************
# Command parser
# **************

sub command_exists {
	my $self = shift;
	my $cmd = shift;
	
	return undef unless defined $cmd;
	
	my $substr_index = $self->cmds_substr_index;
	my $cmd_match = $substr_index->{lc $cmd};
	return $cmd_match if $cmd_match;
	return [];
}

sub command_strip {
	my $self = shift;
	my $cmd = shift;
	
	return undef unless defined $cmd and exists $command{lc $cmd};
	return $command{lc $cmd}{'strip'};
}

sub parse_cmd {
	my $self = shift;
	my ($irc,$sender,$channel,$cmd,$args,$queued) = @_;
	
	unless ($command{$cmd}{on}) {
		$self->print_debug("[$channel] ($sender) Command disabled: $cmd");
		$irc->yield(notice => $sender => "Error: command $cmd has been disabled.");
		return '';
	}
	
	if ($self->check_access($irc, $sender, $channel, $command{$cmd}{access})) {
		my $sub = __PACKAGE__->can($command{$cmd}{func});
		return $self->$sub($irc, $sender, $channel, $args);
	}
	
	if ($queued) { # Result of queued command; user does not have access
		$irc->yield(privmsg => $sender => "You do not have access to run the command '$cmd'.");
	} else {
		if ($self->queue_cmd_exists($sender)) {
			$channel = $sender unless $channel;
			$irc->yield(privmsg => $channel => "$sender: Please wait for your previous command to process.");
		} else {
			$self->queue_cmd($sender, $channel, $cmd, $args);
			$irc->yield(whois => $sender);	
		}
	}
	
	return '';
}

sub check_access {
	my $self = shift;
	my ($irc, $sender, $channel, $req_access) = @_;
	
	return 1 if $req_access == ACCESS_NONE;
	
	if ($channel) {
		if (($self->state_channel_user($channel, $sender)//0) >= $req_access) {
			$self->print_debug("$sender has necessary channel access in $channel");
			return 1;
		}
	}
	
	if ($self->state_user_exists($sender)) {
		if ($req_access <= ACCESS_BOTADMIN and $self->state_user($sender, 'ircop')) {
			$self->print_debug("$sender has IRCop access");
			return 1;
		}
		
		my $ident = $self->state_user($sender, 'ident');
		if (defined $ident) {
			if (($req_access <= ACCESS_MASTER and lc $ident eq lc $self->config_var('master')) or
					($req_access <= ACCESS_BOTADMIN and grep { lc $ident eq lc $_ } @{$self->db_var('admins')}) or
					($req_access <= ACCESS_VOICE and grep { lc $ident eq lc $_ } @{$self->db_var('voices')})) {
				$self->print_debug("$sender has necessary internal access");
				return 1;
			}
		}
	}
	
	return 0;
}

sub cmd_enable {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)/) {
		my $cmd = lc $1;
		if (exists $command{$cmd}) {
			unless ($command{$cmd}->{on}) {
				if ($command{$cmd}->{access} < ACCESS_MASTER or
						lc $self->state_user($sender, 'ident') eq lc $self->config_var('master')) {
					$command{$cmd}->{on} = 1;
					$self->print_debug("Command '$cmd' has been enabled by $sender.");
					$irc->yield(privmsg => $channel => "Command '$cmd' has been enabled.");
				} else {
					$irc->yield(privmsg => $channel => "This command can only be enabled with master access.");
				}
			} else {
				$irc->yield(primvsg => $channel => "Command '$cmd' is already enabled.");
			}
		} else {
			$irc->yield(privmsg => $channel => "No such command '$cmd'.");
		}
	} else {
		$irc->yield(privmsg => $channel => "Syntax: ~enable command");
	}
}

sub cmd_disable {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)/) {
		my $cmd = lc $1;
		if (exists $command{$cmd}) {
			if ($command{$cmd}->{on}) {
				if ($command{$cmd}->{access} < ACCESS_MASTER or
						lc $self->state_user($sender, 'ident') eq lc $self->config_var('master')) {
					$command{$cmd}->{on} = 0;
					$self->print_debug("Command '$cmd' has been disabled by $sender.");
					$irc->yield(privmsg => $channel => "Command '$cmd' has been disabled.");
				} else {
					$irc->yield(privmsg => $channel => "This command can only be disabled with master access.");
				}
			} else {
				$irc->yield(privmsg => $channel => "Command '$cmd' is already disabled.");
			}
		} else {
			$irc->yield(privmsg => $channel => "No such command '$cmd'.");
		}
	} else {
		$irc->yield(privmsg => $channel => "Syntax: ~disable command");
	}
}

sub cmd_conf {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	if ($args =~ /^([[:graph:]]+) *(on|off)?/) {
		my $cfg = lc $1;
		my $set = lc $2;
		my $cur_value = $self->config_var($cfg);
		if (defined $cur_value and $cur_value =~ /^[01]$/) {
			if ($set eq 'on' or $set eq '1') {
				$self->print_debug("$cfg set by $sender.");
				$irc->yield(privmsg => $channel => "$cfg turned on.");
				$self->config_var($cfg, 1);
				$self->store_config_var($cfg);
			}
			elsif ($set eq 'off' or $set eq '0') {
				$self->print_debug("$cfg cleared by $sender.");
				$irc->yield(privmsg => $channel => "$cfg turned off.");
				$self->config_var($cfg, 0);
				$self->store_config_var($cfg);
			}
			else {
				$self->print_debug("$cfg status requested by $sender.");
				$irc->yield(privmsg => $channel => "$cfg is on") if $cur_value;
				$irc->yield(privmsg => $channel => "$cfg is off") if !$cur_value;
			}
		}
		else {
			$self->print_debug("Invalid configuration item $cfg");
			$irc->yield(privmsg => $channel => "Invalid configuration: $cfg");
		}
	}
}

sub cmd_save {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	$self->print_debug("Saving by request of $sender.");
	$irc->yield(privmsg => $channel => "Configuration saved.");
	$self->store_config;
}

sub cmd_reload {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	$self->print_debug("Reloading by request of $sender.");
	$irc->yield(privmsg => $channel => "Configuration reloaded.");
	$self->load_config;
}

sub cmd_spellmode {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (lc $args =~ /^nazi/ and !$channel) { return; }
	if (!$channel) { $channel = $sender; }
	if (lc $args eq 'ultra' or lc $args eq 'fast' or lc $args eq 'normal' or lc $args eq 'bad-spellers') {
		$self->print_debug("Spelling suggestion mode set to $args by $sender");
		$irc->yield(privmsg => $channel => "Spelling suggestion mode set to $args");
		$self->config_var('spellmode', lc $args);
		$self->speller(1);
	}
	elsif (lc $args eq 'nazi on') {
		$self->print_debug("Spelling nazi mode enabled in $channel by $sender");
		$irc->yield(privmsg => $channel => "Spelling nazi mode enabled.");
		$self->state_channel($channel, 'nazi', 1);
	}
	elsif (lc $args eq 'nazi off') {
		$self->print_debug("Spelling nazi mode disabled in $channel by $sender");
		$irc->yield(privmsg => $channel => "Spelling nazi mode disabled.");
		$self->state_channel($channel, 'nazi', 0);
	}
	else {
		$self->print_debug("Spelling suggestion mode requested by $sender.");
		my $curmode = $self->config_var('spellmode');
		$irc->yield(privmsg => $channel => "Spelling suggestion mode is $curmode");
	}
}

sub cmd_sysinfo {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $si = $self->sysinfo->get;
	my $b_code = chr(2); # how bold is read
	
	my @si_order = ( 'hostname', 'domain', 'kernel', 'release', 'version',
			'countcpus', 'memtotal', 'swaptotal', 'uptime', 'idletime' );
	
	my $sistring = 'SysInfo: ';
	$sistring .= "$b_code$_:$b_code $si->{$_} " foreach @si_order;
	$self->print_debug("Printing system information");
	$irc->yield(privmsg => $channel => $sistring);
}

sub cmd_joinall {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	$self->autojoin;
	$irc->yield(notice => $channel => "Attempting to join all autojoin channels.");
}

sub cmd_join {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $channeljoin = 0;
	if ($args =~ /^(\#[[:graph:]]+)/) { $channeljoin = $1; }
	elsif ($args =~ /^([[:graph:]]+)/) { $channeljoin = "#$1"; }
	if ($channeljoin) {
		$self->print_debug("Requested to join $channeljoin by $sender. Attempting to join...");
		$irc->yield(join => $channeljoin);
	}
	else {
		$self->print_debug("Requested to join invalid channel by $sender: $args");
		$irc->yield(privmsg => $sender => "No channel specified.");
	}
}

sub cmd_leave {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->cmd_fuckoff(@_) unless $channel;
	if ($channel) {
		my $channels = $self->db_var('channels');
		if (grep {lc $channel eq lc $_} @$channels) {
			$self->print_debug("Leaving $channel and removing from autojoin list");
			$irc->yield(privmsg => $channel => "Removing $channel from autojoin list");
			my @tempchans;
			my $chancount = scalar @$channels;
			foreach (0..$chancount-1) {
				push @tempchans, $channels->[$_] unless lc $channels->[$_] eq lc $channel;
			}
			$self->db_var('channels', \@tempchans);
			$self->store_db;
		} else {
			$self->print_debug("Leaving $channel");
		}
		$irc->yield(part => $channel => $args);
	}
}

sub cmd_fuckoff {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $channelpart = 0;
	my $msg = '';
	if ($args =~ /^(\#[[:graph:]]+)( +([[:print:]]+))?$/) {
		$channelpart = $1;
		$msg = $2;
	}
	elsif ($channel) {
		$channelpart = $channel;
		$msg = $args;
	}
	elsif ($args =~ /^([[:graph:]]+)( +([[:print:]]+))?$/) {
		$channelpart = "#$1";
		$msg = $2;
	}
	if ($channelpart) {
		$self->print_debug("Received leave command from $sender for $channelpart.");
		#$irc->yield(privmsg => $channelpart => "Bye.");
		if (!$msg) { $msg = "Requested to leave by $sender"; }
		$irc->yield(part => $channelpart => $msg);
	}
	else {
		$self->print_debug("Received leave command from $sender with invalid channel string: $args");
		$irc->yield(privmsg => $sender,"No channel specified.");
	}
}

sub cmd_quit {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Quitting at request of $sender.");
	if (!$args) { $args = "Requested to quit by $sender"; }
	$self->is_stopping(1);
	$irc->yield(join => '0');
	$irc->yield(quit => $args);
}

sub cmd_restart {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Restarting at request of $sender.");
	if (!$args) { $args = "Requested to restart by $sender"; }
	$irc->yield(join => '0');
	$irc->yield(quit => $args);
}

sub cmd_say {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $channelsay = 0;
	if ($args =~ /^(\#[[:graph:]]+) +([[:print:]]+?)$/) { $channelsay = $1; $args = $2; }
	elsif ($channel) { $channelsay = $channel; }
	if ($channelsay) { $self->print_debug("Received say command from $sender for $channelsay."); }
	else {
		$self->print_debug("Received say command from $sender privately.");
		$channelsay = $sender;
	}
	$irc->yield(privmsg => $channelsay," - $args");
}

sub cmd_me {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $channelme = 0;
	if ($args =~ /^(\#[[:graph:]]+) +([[:print:]]+?)$/) { $channelme = $1; $args = $2; }
	elsif ($channel) { $channelme = $channel; }
	if ($channelme) { $self->print_debug("Received me command from $sender for $channelme."); }
	else {
		$self->print_debug("Received me command from $sender privately.");
		$channelme = $sender;
	}
	$irc->yield(ctcp => $channelme => "ACTION $args");
}

sub cmd_ping {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($channel) { $self->print_debug("Pinged by $sender in $channel."); }
	else {
		$self->print_debug("Pinged by $sender privately.");
		$channel = $sender;
	}
	$irc->yield(privmsg => $channel => "Pong.");
}

sub cmd_ding {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($channel) { $self->print_debug("Dinged by $sender in $channel."); }
	else {
		$self->print_debug("Dinged by $sender privately.");
		$channel = $sender;
	}
	$irc->yield(privmsg => $channel => "Dong.");
}

sub cmd_version {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Version request by $sender");
	my $version = $self->bot_version;
	$irc->yield(notice => $sender => "Paperbot $version written by Grinnz");
}

sub cmd_addquote {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $numquotes = $self->num_quotes;
	if ($channel) { $self->print_debug("Quote #".($numquotes+1)." added by $sender in $channel."); }
	else {
		$self->print_debug("Quote #".($numquotes+1)." added by $sender privately.");
		$channel = $sender;
	}
	$self->add_quote($args);
	$irc->yield(privmsg => $channel => "Quote #".($numquotes+1)." added.");
}

sub cmd_quoten { my $self = shift; my $sub = \&cmd_quote; return $self->$sub(@_, 1); }

sub cmd_quote {
	my $self = shift;
	my ($irc,$sender,$channel,$args,$not) = @_;
	$args =~ s/[[:space:]]+$//;
	if ($channel) { $self->print_debug("Quote requested by $sender in $channel."); }
	else {
		$self->print_debug("Quote requested by $sender privately.");
		$channel = $sender;
	}
	my $quotecount = $self->num_quotes;
	if (!$quotecount) { # No quotes available
		$irc->yield(privmsg => $channel => "No quotes available.");
		return;
	}
	my $re;
	if ($args eq '') { # Random quote
		my $quotenum = int(rand($quotecount))+1;
		$self->print_debug("Sending quote $quotenum.");
		my $quote = $self->quote($quotenum);
		$irc->yield(privmsg => $channel => "[$quotenum] $quote");
	}
	# Specific number requested
	elsif ($args =~ /^(-?\d+)$/) {
		my $quotenum = $1;
		if ($quotenum <= 0) {
			$self->print_debug("Quote $quotenum requested, sending first quote");
			$irc->yield(privmsg => $channel => "Quotes start at 1. Sending first quote:");
			$quotenum = 1;
		}
		if ($quotenum > $quotecount) {
			$self->print_debug("Quote $quotenum requested, only ".$quotecount." exist.");
			$irc->yield(privmsg => $channel => "Only $quotecount quotes exist. Sending last quote:");
			$quotenum = $quotecount;
		}
		$self->print_debug("Sending quote $quotenum.");
		my $quote = $self->quote($quotenum);
		$irc->yield(privmsg => $channel => "[$quotenum] $quote");
	}
	elsif ((my $nummatch = $args =~ /^(.*?)[[:space:]]+(\d+)$/ and
			defined eval { $re = qr/$1/i; }) or 
			defined eval { $re = qr/$args/i; }) { # Regex search term
		my $resultnum;
		if ($nummatch) {
			$resultnum = $2-1;
			$args = $1;
		}
		my $results = [];
		# Check cache
		my $cache_results = $not ? $self->cache_quoten_results($args) : $self->cache_quote_results($args);
		if (!defined $cache_results) {
			my $pid = open(my $quote_handle, '-|') // die "Unable to open child for parsing quotes";
			if ($pid) { # parent
				$self->child_handle($pid, $quote_handle);
				$self->io_select->add($quote_handle);
				my $start = time;
				my $completed;
				my $data = '';
				while (time - $start <= 10) {
					my @ready = $self->io_select->can_read(1);
					next unless grep { fileno $_ == fileno $quote_handle } @ready;
					my $buf = '';
					my $bytes = sysread $quote_handle, $buf, 8192;
					unless ($bytes) { $completed = 1; last; }
					$data .= $buf;
					$start = time;
				}
				$self->io_select->remove($quote_handle);
				unless ($completed) {
					kill 9, $pid;
				}
				close $quote_handle or warn "Child exited with return status $?";
				$self->child_handle_delete($pid);
				if ($not) {
					$cache_results = $self->cache_quoten_results($args, [grep { length } (split "\n", $data)]);
				} else {
					$cache_results = $self->cache_quote_results($args, [grep { length } (split "\n", $data)]);
				}
			}
			else
			{
				my $start = time;
				foreach my $num (1..$quotecount) {
					die if time > $start + 60;
					my $quote = $self->quote($num);
					if ((defined $not and $quote !~ $re) or
							(!defined $not and $quote =~ $re)) {
						print "$num\n";
					}
				}
				exit;
			}
		}
		else { $self->print_debug("Retrieved from cache."); }
		my @temparray = @$cache_results;
		$results = \@temparray;
		
		my $resultcount = scalar @{$results};
		if ($resultcount) {
			unless (defined $resultnum and $resultnum >= 0 and
					$resultnum < $resultcount) {
				$resultnum = int(rand($resultcount));
				my $cache_last_id = $not ? $self->cache_quoten_last_id($args) : $self->cache_quote_last_id($args);
				if (defined $cache_last_id and $resultcount > 1) {
					$resultnum = int(rand($resultcount)) while $resultnum == $cache_last_id;
				}
			}
			if ($not) {
				$self->cache_quoten_last_id($args, $resultnum);
			} else {
				$self->cache_quote_last_id($args, $resultnum);
			}
			my $quotenum = $results->[$resultnum];
			$self->print_debug("Sending quote $quotenum [".($resultnum+1)."/$resultcount]");
			my $quote = $self->quote($quotenum);
			$irc->yield(privmsg => $channel => "[$quotenum] $quote (".($resultnum+1)."/$resultcount)");
		}
		else {
			my $qual = '';
			$qual = ' not' if defined $not;
			$self->print_debug("No quote$qual matching '$args' found.");
			$irc->yield(privmsg => $channel => "No quote$qual matching '$args' found.");
		}
	}
	else {
		$self->print_debug("Invalid regex string $args: $@");
		$irc->yield(privmsg => $channel => "Error: $@");
	}
}

sub cmd_listquotes {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Quote list requested by $sender.");
	my $quotecount = $self->num_quotes;
	$channel = $sender unless $channel;
	$irc->yield(privmsg => $channel => "$quotecount quotes available. Sending...");
	$channel = $sender;
	foreach (1..$quotecount) {
		my $quote = $self->quote($_);
		$irc->yield(privmsg => $channel => "[$_] $quote");
		sleep 1;
	}
	if ($quotecount == 0) { $irc->yield(privmsg => $channel => "No quotes currently available."); }
}

sub cmd_delquote {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($channel) { $self->print_debug("Quote deleted by $sender in $channel."); }
	else {
		$self->print_debug("Quote deleted by $sender privately.");
		$channel = $sender;
	}
	my $quotecount = $self->num_quotes;
	if ($args =~ /^(\d+)$/ and $1 > 0 and $1 <= $quotecount) {
		my $quotenum = $1;
		$self->del_quote($quotenum);
		$irc->yield(privmsg => $channel => "Quote $quotenum deleted.");
	}
#	elsif ($args eq 'all' and lc $self->state_user($sender, 'ident') eq lc $self->config_var('master')) {
#		$self->{'quotes'} = [];
#		$self->store_quotes;
#		$self->cache_quote_clear;
#		$self->cache_quoten_clear;
#	}
	else { $irc->yield(privmsg => $channel =>  "Invalid quote ID. $quotecount quotes available."); }
}

sub cmd_help {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Help file requested by $sender");
	$irc->yield(notice => $sender => 'My helpfile may be viewed at http://grinnz.net/paper.html');
}

sub cmd_todo
{
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $todo = $self->db_var('todo');
	if ( $args )
	{
		push @$todo, $args;
		my $size = scalar @$todo;
		$irc->yield(privmsg =>  $channel, "Added item #$size to the todo list." );
	}
	else
	{
		if ( @$todo )
		{
			$irc->yield(privmsg =>  $channel, "Displaying the todo list:" );
			my $size = scalar @$todo;
			foreach my $num (1..$size)
			{
				$irc->yield(privmsg =>  $channel, "$num: $todo->[$num-1]" );
			}
		}
		else
		{
			$irc->yield(privmsg =>  $channel, "Nothing to do!" );
		}
	}
}


sub cmd_done
{
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $todo = $self->db_var('todo');
	my $size = scalar @$todo;
	if ($args =~ /^\d+$/ and $args > 0 and $args <= $size )
	{
		my $removed = splice @$todo,$args-1,1;
		$irc->yield(privmsg =>  $channel, "Todo item #$args ($removed) removed." );
		#cmd_todo($irc,$sender,$channel,'');
	}
	elsif ($size == 0)
	{
		$irc->yield(privmsg => $channel =>  "The todo list is empty.");
	}
	else {
		$irc->yield(privmsg => $channel => "Invalid selection. Valid args are 1-$size.");
	}
}

#sub cmd_seen {
#	my $self = shift;
#	my ($irc,$sender,$channel,$args) = @_;
#	if ($args =~ /^([[:graph:]]+)/) {
#	my $user = $1;
#	if (!$channel) { $channel = $sender; }
#	$self->print_debug("$sender asked if I have seen $user.");
#	
#	my $ishere = '';
#	my $away = '';
#	if (exists $userlist->{lc $user} and exists $userlist->{lc $user}{status}{lc $channel}) {
#		$ishere = "$user is right here. ";
#	}
#	if (exists $userlist->{lc $user} and $userlist->{lc $user}{away}) {
#		$away = ' [away]';
#	}
#
#	if (lc $user eq lc $sender) {
#		$irc->yield(privmsg => $channel => "Have you seen yourself?");
#	}
#	elsif (lc $user eq lc $conf->{nick}) {
#		$irc->yield(privmsg => $channel => "I'm right here.");
#	}
#	elsif (exists $seen->{lc $user} and exists $seen->{lc $user}{action}) {
#		my $seenmsg = $seen->{lc $user}{action};
#		my $seentime = ago_exact(time()-$seen->{lc $user}{time});
#		my $seenchan = '';
#		my $away = '';
#		my $quithost = '';
#		my $quitmsg = '';
#		if (lc $channel eq lc $seen->{lc $user}{channel}) {
#		$seenchan = 'this channel';
#		}
#		elsif ($seen->{lc $user}{channel}) { $seenchan = 'another channel'; }
#		elsif ($seenmsg eq 'quitting') {
#		$quithost = ' ('.$seen->{lc $user}{host}.')';
#		$quitmsg = ' ('.$seen->{lc $user}{quitmsg}.')';
#		}
#		$irc->yield(privmsg => $channel => " $ishere$user$quithost was last seen $seenmsg$seenchan$quitmsg, $seentime.");
#	}
#	else {
#		$irc->yield(privmsg => $channel => " $ishere I have not seen $user$away do anything.");
#	}
#	}
#}

sub cmd_queue_info {
	my $self = shift;
	my ($irc,$sender,$channel,$args,$type) = @_;
	my $target = $sender;
	if ($args =~ /^([[:graph:]]+)/) {
		$target = $1;
	}
	$self->print_debug("$type info of $target requested by $sender.");
	if (!$self->queue_whois_exists($sender)) {
		$self->queue_whois($target, $channel, $type, $sender);
		$irc->yield(whois => $target);
	}
	else {
		$irc->yield(privmsg => $channel => "$sender: Please repeat command in a few seconds.");
	}
}

sub cmd_whois { return cmd_queue_info(@_,'user'); }
sub cmd_whoami { return cmd_whois(@_[0..3],$_[2]); }
sub cmd_away { return cmd_queue_info(@_,'away'); }
sub cmd_idle { return cmd_queue_info(@_,'idle'); }

sub cmd_access {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $target = $sender;
	if ($args =~ /^([[:graph:]]+)/) {
		$target = $1;
	}
	$self->print_debug("access info of $target requested by $sender.");
	if ($self->state_user_exists($target) and $self->state_user($target, 'cached')) {
		$self->say_userinfo($irc, 'access', $sender, $channel, $target);
	} else {
		return $self->cmd_queue_info($irc,$sender,$channel,$target,'access');
	}
}

sub cmd_dns {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $target = $sender;
	if ($args =~ /^([[:graph:]]+)/) {
		$target = $1;
	}
	$self->print_debug("dns info of $target requested by $sender.");
	if ($self->state_user_exists($target) or $target =~ /[.:]/) {
		$self->say_userinfo($irc, 'dns', $sender, $channel, $target);
	} else {
		$self->cmd_queue_info($irc,$sender,$channel,$target,'dns');
	}
}

sub cmd_rdns {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)/) {
		my $address = $1;
		$self->print_debug("rdns of $address requested by $sender.");
		
		my $type = 'PTR';

		my $result = $self->resolver->resolve(
			type	=> $type,
			host	=> $address,
			context	=> { irc => $irc, question => $address, channel => $channel },
			event	=> 'dns_response',
		);
		if (defined $result) {
			my @args;
			$args[ARG0] = $result;
			splice @args, 0, 1;
			$self->dns_response(@args);
		}
	}
}

sub cmd_nicks {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($args =~ /^([[:graph:]]+)/) {
		my $user = $1;
		if (!$channel) { $channel = $sender; }
		$self->print_debug("Nicks of $user requested by $sender.");
		#if (exists $seen->{lc $user}) {
		#	$irc->yield(privmsg => $channel => "Known nicks of $user: @{$seen->{lc $user}{nicks}}");
		#}
	}
}

sub cmd_topic {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($channel and !$self->queue_topic_exists($channel)) {
		$self->queue_topic($channel);
		$irc->yield(topic => $channel);
	}
}

sub cmd_fight {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^\s*([[:print:]]+?)\s+v(s\.?|ersus)\s+([[:print:]]+?)\s*$/i) {
		my $champion = $1;
		my $challenger = $3;
		
		my $champ_results = $self->search_google_web_count($champion);
		unless (defined $champ_results) {
			$irc->yield("An error occurred attempting to search Google");
			return;
		}
		$self->print_debug("$champion: $champ_results");
		my $challenge_results = $self->search_google_web_count($challenger);
		unless (defined $challenge_results) {
			$irc->yield("An error occurred attempting to search Google");
			return;
		}
		$self->print_debug("$challenger: $challenge_results");
		
		my $winner = "Winner is \"$champion\"!";
		$winner = "Winner is \"$challenger\"!" if $challenge_results > $champ_results;
		$winner = "It's a tie!" if $challenge_results == $champ_results;
		
		if ($champ_results >= 1000000000) { $champ_results = $champ_results/1000000000 . ' billion'; }
		elsif ($champ_results >= 1000000) { $champ_results = $champ_results/1000000 . ' million'; }
		elsif ($champ_results >= 1000) { $champ_results = $champ_results/1000 . ' thousand'; }
		
		if ($challenge_results >= 1000000000) { $challenge_results = $challenge_results/1000000000 . ' billion'; }
		elsif ($challenge_results >= 1000000) { $challenge_results = $challenge_results/1000000 . ' million'; }
		elsif ($challenge_results >= 1000) { $challenge_results = $challenge_results/1000 . ' thousand'; }
		
		$irc->yield(privmsg => $channel => "Google Fight! \"$champion\": $champ_results, \"$challenger\": $challenge_results. $winner");
	} else {
		$irc->yield(privmsg => $channel => "Syntax: ~fight combatant1 vs. combatant2");
	}
}

sub cmd_google {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	if (length $args) {
		my $safe = 'active';
		$safe = 'off' if $sender eq '-fight';
		
		my $results = $self->search_google_web($args);
		unless (defined $results) {
			$self->cache_search_clear('google');
			$irc->yield(privmsg => $channel => "An error occurred attempting to search Google.");
			return;
		}
		
		$self->cache_search_results('google', $results);
		
		if (@$results) {
			my $r = $self->cache_search_next('google');
			$self->print_debug("[0] ".$r->title." (".$r->url.")");
			my $title = Paper::strip_google($r->title);
			my $url = $r->url;
			$url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
			$irc->yield(privmsg => $channel => "Top result for \"$args\": $title : $url");
		}
		else {
			$irc->yield(privmsg => $channel => "No results for \"$args\"");
		}
	}
	else {
		my $r = $self->cache_search_next('google');
		if (defined $r) {
			my $title = Paper::strip_google($r->title);
			my $url = $r->url;
			my $index = $self->cache_search_index('google');
			$self->print_debug("[$index] $title ($url)");
			$irc->yield(privmsg => $channel => "Next result: $title : $url");
		}
		else {
			$irc->yield(privmsg => $channel => "No more results");
			$self->cache_search_clear('google');
		}
	}
}

sub cmd_youtube {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if (!$channel) { $channel = $sender; }
	if (length $args) {
		my $results = $self->search_youtube($args);
		if (defined $results) {
			$self->cache_search_results('youtube', $results);
		} else {
			$irc->yield(privmsg => $channel => "YouTube Search: No results");
			return;
		}
	}
	
	my $video = $self->cache_search_next('youtube');
	if (defined $video) {
		$self->print_debug("Video result: " . $video->title . "");
		my $b_code = chr(2);
		my @links = grep { $_->rel eq 'alternate' } $video->link;
		my $href = @links ? $links[0]->href : $video->link->href;
		$irc->yield(privmsg => $channel => "YouTube Search Result: " . $b_code . $video->title . $b_code
			. " | uploaded by " . $video->author->name . " | " . $href);
	} else {
		$irc->yield(privmsg => $channel => "No more results");
		$self->cache_search_clear('youtube');
	}
}

sub cmd_youtubeinfo {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	my $video_id = '';
	my $hash = '';
	
	if ($args =~ /^(http:\/\/)?(www\.)?youtube\.com\/watch\?v=([[:alnum:]\-_]+)[^#\s]*(#[[:graph:]]+)?/) {
		$video_id = $3;
		$hash = $4;
	} elsif ($args) {
		$video_id = $args;
	} else {
		$irc->yield(privmsg => $channel => "You must supply a YouTube Video ID or URI.");
		return;
	}
	
	my $video = $self->search_youtube_id($video_id);

	if (defined $video) {
		$self->print_debug("Displaying info for video: " . $video->title . "");
		my $b_code = chr(2);
		my @links = grep { $_->rel eq 'alternate' } $video->link;
		my $href = @links ? $links[0]->href : $video->link->href;
		$href .= $hash if defined $hash;
		$irc->yield(privmsg => $channel => "YouTube Video linked by $sender: " . $b_code . $video->title . $b_code . " | " . $href);
		my $description = $video->content->body;
		if (length $description > 250) {
			$description = substr $description, 0, 250;
			$description .= '...';
		}
		$description =~ s/^(\s*\n\s*)+//;
		$description =~ s/(\s*\n\s*)+$//;
		$description =~ s/(\s*\n\s*)+/ | /g;
		$irc->yield(privmsg => $channel => "Author: " . $video->author->name . " | Description: " . $description);
	} else {
		$irc->yield(privmsg => $channel => "No such video indexed");
	}
}

sub cmd_wiki {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	if (defined $args and length $args) {
		my $pages = $self->search_wikipedia_titles($args);
		
		if (defined $pages and @$pages) {
			$self->cache_search_results('wikipedia', $pages);
		} else {
			$irc->yield(privmsg => $channel => "No results for \"$args\"");
			return;
		}
	}
	
	my $title = $self->cache_search_next('wikipedia');
	if (defined $title) {
		my $content = $self->search_wikipedia_content($title);
		if (defined $content) {
			$self->print_debug("Wikipedia page found: " . $title);
			my $b_code = chr(2);
			#my $extract = Paper::strip_wide($content->{'extract'});
			my $extract = $content->{'extract'};
			$extract =~ s/\n/ /g;
			$irc->yield(privmsg => $channel => "Wikipedia result: " . $b_code . $content->{'title'} . $b_code . " : " . $content->{'fullurl'} . " : $extract");
		} else {
			$irc->yield(privmsg => $channel => "No page found for \"$title\"");
		}
	} else {
		$irc->yield(privmsg => $channel => "No more results");
	}
}

sub cmd_spell {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($args =~ /^([[:graph:]]+)/) {
		my $word = $1;
		$self->print_debug("Checking spelling of $word");
		if (!$channel) { $channel = $sender; }
		my $speller = $self->speller;
		my $result = $speller->check($word);
		if ($result) { $irc->yield(privmsg => $channel => " - $word is a word."); }
		elsif (defined $result) {
			my @suggestions = $speller->suggest($word);
			my $suggest_str = 'No suggestions.';
			if (@suggestions) {
				splice @suggestions, 100 if @suggestions > 100;
				$suggest_str = join ' ', @suggestions;
			}
			$irc->yield(privmsg => $channel => "Not found: $word. Suggestions: $suggest_str");
		} else {
			my $err = $speller->errstr;
			$irc->yield(privmsg => $channel => "Internal error: $err");
		}
	}
}

sub cmd_define {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($args =~ /^([[:graph:]]+)/) {
		my $word = $1;
		$self->print_debug("Checking definition of $word");
		$channel = $sender unless $channel;
		#my $meanings = $dictionary->define($word);
		my @list;
		#push @list,$_->[1] foreach @{$meanings};
		$self->print_debug("$word: @list");
	}
}

sub cmd_calc {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Evaluating expression: $args");
	if (!$channel) { $channel = $sender; }
	
	my $error;
	my $parsed_expr = calc_parse_expression($args, \$error);
	unless (defined $parsed_expr) {
		$self->print_debug("Parse error: $error");
		$irc->yield(privmsg => $channel => "Error: $error");
		return;
	}
	unless (@$parsed_expr) {
		$self->print_debug("Nothing to do");
		$irc->yield(privmsg => $channel => "Error: No expression given");
		return;
	}
	
	my $expr_string = join ' ', (map { $_->{'value'} } @$parsed_expr);
	$self->print_debug("Parsed expression: $expr_string");
	
	undef $error;
	my $answer = calc_evaluate_expression($parsed_expr, \$error);
	if (defined $answer) {
		$self->print_debug("Result: $answer");
		$irc->yield(privmsg => $channel => "Result: $answer");
	} else {
		$self->print_debug("Evaluation error: $error");
		$irc->yield(privmsg => $channel => "Error: $error");
	}
}

my %operators = (
	'+' => { 'equal' => { '+' => 1, '-' => 1 }, 'less' => { '*' => 1, '/' => 1, '^' => 1, 'uminus' => 1 }, 'assoc' => 'left' },
	'-' => { 'equal' => { '+' => 1, '-' => 1 }, 'less' => { '*' => 1, '/' => 1, '^' => 1, 'uminus' => 1 }, 'assoc' => 'left' },
	'*' => { 'greater' => { '+' => 1, '-' => 1 }, 'equal' => { '*' => 1, '/' => 1 }, 'less' => { '^' => 1, 'uminus' => 1 }, 'assoc' => 'left' },
	'/' => { 'greater' => { '+' => 1, '-' => 1 }, 'equal' => { '*' => 1, '/' => 1 }, 'less' => { '^' => 1, 'uminus' => 1 }, 'assoc' => 'left' },
	'uminus' => { 'greater' => { '+' => 1, '-' => 1, '*' => 1, '/' => 1 }, 'equal' => { 'uminus' => 1 }, 'less' => { '^' => 1 }, 'assoc' => 'right' },
	'^' => { 'greater' => { '+' => 1, '-' => 1, '*' => 1, '/' => 1, 'uminus' => 1 }, 'equal' => { '^' => 1 }, 'assoc' => 'right' },
#	'!' => { 'greater' => { '+' => 1, '-' => 1, '*' => 1, '/' => 1, 'uminus' => 1 }, 'equal' => { '!' => 1 }, 'assoc' => 'left' },
);

my %functions = (
	'+' => { 'args' => 2, 'sub' => sub { $_[0] + $_[1] } },
	'-' => { 'args' => 2, 'sub' => sub { $_[0] - $_[1] } },
	'*' => { 'args' => 2, 'sub' => sub { $_[0] * $_[1] } },
	'/' => { 'args' => 2, 'sub' => sub { $_[0] / $_[1] } },
	'uminus' => { 'args' => 1, 'sub' => sub { -$_[0] } },
	'^' => { 'args' => 2, 'sub' => sub { $_[0] ** $_[1] } },
#	'!' => { 'args' => 1, 'sub' => sub { },
	'sqrt' => { 'args' => 1, 'sub' => sub { sqrt($_[0]) } },
	'pi' => { 'args' => 0, 'sub' => sub { pi } },
	'i' => { 'args' => 0, 'sub' => sub { i } },
	'e' => { 'args' => 0, 'sub' => sub { exp(1) } },
	'ln' => { 'args' => 1, 'sub' => sub { log($_[0]) } },
	'log' => { 'args' => 1, 'sub' => sub { log($_[0])/log(10) } },
	'logn' => { 'args' => 2, 'sub' => sub { log($_[0])/log($_[1]) } },
	'sin' => { 'args' => 1, 'sub' => sub { sin($_[0]) } },
	'cos' => { 'args' => 1, 'sub' => sub { cos($_[0]) } },
	'tan' => { 'args' => 1, 'sub' => sub { tan($_[0]) } },
	'asin' => { 'args' => 1, 'sub' => sub { asin($_[0]) } },
	'acos' => { 'args' => 1, 'sub' => sub { acos($_[0]) } },
	'atan' => { 'args' => 1, 'sub' => sub { atan($_[0]) } },
	'int' => { 'args' => 1, 'sub' => sub { int($_[0]) } },
	'floor' => { 'args' => 1, 'sub' => sub { POSIX::floor($_[0]) } },
	'ceil' => { 'args' => 1, 'sub' => sub { POSIX::ceil($_[0]) } }
);

my $operators_re = '[-+*/^]';
my $calc_re = qr/((0x[0-9a-f]+|0b[01]+|0[0-7]+)|(\d*\.)?\d+(e-?\d+)?|[()]|\w+|,|$operators_re)/i;

sub calc_parse_expression {
	my ($expr, $error) = @_;
	
	my $tmp_error;
	$error = \$tmp_error unless defined $error and ref $error eq 'SCALAR';

	my @oper_stack;
	my @expr_queue;

	my $binop_possible;
	my $last_token;
	while ($expr =~ /$calc_re/g) {
		my $token = $1;
		
		# Handle octal/hex/binary numbers
		if (defined $2 and length $2) {
			$token = oct($token);
		}
		
		# Handle implicit multiplication
		if ($binop_possible and $token !~ /^($operators_re|\)|,)$/i) {
			my $shunted = calc_shunt_operator(\@expr_queue, \@oper_stack, '*');
		}
		
		if ($token =~ /^$operators_re$/) {
			if ($token eq '-') { # Detect unary minus
				if (!$binop_possible) {
					$token = 'uminus';
				}
			}
			my $shunted = calc_shunt_operator(\@expr_queue, \@oper_stack, $token);
			$binop_possible = 0;
		} elsif (looks_like_number($token)) {
			my $shunted = calc_shunt_number(\@expr_queue, \@oper_stack, $token);
			$binop_possible = 1;
		} elsif ($token eq '(') {
			my $shunted = calc_shunt_left_paren(\@expr_queue, \@oper_stack, $token);
			$binop_possible = 0;
		} elsif ($token eq ')') {
			my $shunted = calc_shunt_right_paren(\@expr_queue, \@oper_stack, $token);
			unless (defined $shunted) {
				$$error = "Mismatched parentheses";
				return undef;
			}
			$binop_possible = 1;
		} elsif ($token =~ /^\w+$/) {
			unless (exists $functions{$token}) {
				$$error = "Invalid function: $token";
				return undef;
			}
			if ($functions{$token}{'args'}) {
				my $shunted = calc_shunt_function_args(\@expr_queue, \@oper_stack, $token);
				$binop_possible = 0;
			} else {
				my $shunted = calc_shunt_function_noargs(\@expr_queue, \@oper_stack, $token);
				$binop_possible = 1;
			}
		} elsif ($token eq ',') {
			my $shunted = calc_shunt_comma(\@expr_queue, \@oper_stack, $token);
			unless (defined $shunted) {
				$$error = "Misplaced comma or mismatched parentheses";
				return undef;
			}
			$binop_possible = 0;
		}
		$last_token = $token;
	}
	
	while (@oper_stack) {
		if ($oper_stack[-1]{'type'} eq 'paren') {
			$$error = "Mismatched parentheses";
			return undef;
		}
		push @expr_queue, (pop @oper_stack);
	}
	
	return \@expr_queue;
}

sub calc_shunt_number {
	my ($expr_queue, $oper_stack, $value) = @_;
	push @$expr_queue, { 'type' => 'number', 'value' => $value };
	return 1;
}

sub calc_shunt_operator {
	my ($expr_queue, $oper_stack, $value) = @_;
	my $assoc = $operators{$value}{'assoc'};
	while (@$oper_stack and $oper_stack->[-1]{'type'} eq 'operator') {
		my $top_oper = $oper_stack->[-1]{'value'};
		if ($operators{$value}{'less'}{$top_oper} or ($assoc eq 'left' and $operators{$value}{'equal'}{$top_oper})) {
			push @$expr_queue, (pop @$oper_stack);
		} else {
			last;
		}
	}
	push @$oper_stack, { 'type' => 'operator', 'value' => $value };
	return 1;
}

sub calc_shunt_function_args {
	my ($expr_queue, $oper_stack, $value) = @_;
	push @$oper_stack, { 'type' => 'function', 'value' => $value };
	return 1;
}

sub calc_shunt_function_noargs {
	my ($expr_queue, $oper_stack, $value) = @_;
	push @$expr_queue, { 'type' => 'function', 'value' => $value };
	return 1;
}

sub calc_shunt_left_paren {
	my ($expr_queue, $oper_stack) = @_;
	push @$oper_stack, { 'type' => 'paren', 'value' => '(' };
	return 1;
}

sub calc_shunt_right_paren {
	my ($expr_queue, $oper_stack) = @_;
	while (@$oper_stack and $oper_stack->[-1]{'type'} ne 'paren') {
		push @$expr_queue, (pop @$oper_stack);
	}
	unless (@$oper_stack and $oper_stack->[-1]{'type'} eq 'paren') {
		return undef;
	}
	pop @$oper_stack;
	if (@$oper_stack and $oper_stack->[-1]{'type'} eq 'function') {
		push @$expr_queue, (pop @$oper_stack);
	}
	return 1;
}

sub calc_shunt_comma {
	my ($expr_queue, $oper_stack) = @_;
	while (@$oper_stack and $oper_stack->[-1]{'type'} ne 'paren') {
		push @$expr_queue, (pop @$oper_stack);
	}
	unless (@$oper_stack and $oper_stack->[-1]{'type'} eq 'paren') {
		return undef;
	}
	return 1;
}

sub calc_evaluate_expression {
	my ($expr_queue, $error) = @_;
	
	my $tmp_error;
	$error = \$tmp_error unless defined $error and 'SCALAR' eq ref $error;

	my @eval_stack;
	foreach my $token (@$expr_queue) {
		if ($token->{'type'} eq 'number') {
			push @eval_stack, $token->{'value'};
		} elsif (exists $functions{$token->{'value'}}) {
			my $num_args = $functions{$token->{'value'}}{'args'};
			if (@eval_stack < $num_args) {
				$$error = "Malformed expression";
				return undef;
			}
			my @args;
			@args = splice @eval_stack, -$num_args if $num_args;
			my $result = eval { $functions{$token->{'value'}}{'sub'}(@args); };
			if ($@) {
				$@ =~ s{ at .+? line \d+\.$}{}i;
				$$error = $@;
				return undef;
			}
			push @eval_stack, $result;
		} else {
			$$error = "Invalid function or operator: $token->{'value'}";
			return undef;
		}
	}
	
	if (@eval_stack > 1) {
		$$error = "Malformed expression";
		return undef;
	}
	
	return $eval_stack[0];
}

sub cmd_clear {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Clearing cached data at request of $sender.");
	if (!$channel) { $channel = $sender; }
	$irc->yield(privmsg => $channel => "Cleared cache.");
	foreach ($self->state_user_list) {
		$self->state_user($_, 'cached', 0);
	}
	$self->cache_quote_clear;
	$self->cache_quoten_clear;
	$self->cache_search_clear;
	$self->queue_cmd_clear;
	$self->queue_whois_clear;
	$self->queue_topic_clear;
	$self->queue_invite_clear;
}

sub cmd_adduser {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($args =~ /^([[:graph:]]+) +([[:graph:]]+)/) {
		my $user = $1;
		my $access = $2;
		if (lc $user eq lc $self->config_var('master')) { return; }
		if (!$channel) { $channel = $sender; }
		if ($access eq 'voice') {
			$self->cmd_deluser($irc,'-add',$channel,$user);
			$self->print_debug("$sender added $user as voice.");
			$irc->yield(privmsg => $channel => "Added $user as voice.");
			push @{$self->db_var('voices')}, $user;
		}
		elsif ($access eq 'admin') {
			$self->cmd_deluser($irc,'-add',$channel,$user);
			$self->print_debug("$sender added $user as admin.");
			$irc->yield(privmsg => $channel => "Added $user as admin.");
			push @{$self->db_var('admins')}, $user;
			push @{$self->db_var('voices')}, $user;
		}
		elsif ($access eq 'none') {
			cmd_deluser($irc,'-del',$channel,$user);
		}
		else {
			$irc->yield(privmsg => $channel => "Access levels are admin and voice.");
		}
		$self->store_db;
	}
}

sub cmd_deluser {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	if ($args =~ /^([[:graph:]]+)/) {
		my $user = $1;
		if (lc $user eq lc $self->config_var('master')) { return; }
		$self->print_debug("$sender removed $user from access.");
		if (!$channel) { $channel = $sender; }
		$irc->yield(privmsg => $channel => "Removed $user from access.") if $sender ne '-add';
		my @tempvoice = grep { lc $_ ne lc $user } @{$self->db_var('voices')};
		my @tempadmin = grep { lc $_ ne lc $user } @{$self->db_var('admins')};
		$self->db_var('voices', \@tempvoice);
		$self->db_var('admins', \@tempadmin);
		$self->store_db;
	}
}

sub cmd_listchans {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$self->print_debug("Channel list requested by $sender");
	my $channels = $self->db_var('channels');
	$irc->yield(notice => $sender => "Autojoin list: @$channels");
}

sub cmd_stay {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	return unless $channel;
	if (grep {lc $channel eq lc $_} @{$self->db_var('channels')}) {
		$self->print_debug("Requested to stay in $channel by $sender but channel already in autojoin");
		$irc->yield(privmsg => $channel => "Channel $channel already in autojoin list.");
	} else {
		$self->print_debug("Requested to stay in $channel by $sender, adding to autojoin");
		$irc->yield(privmsg => $channel => "Added $channel to autojoin list.");
		push @{$self->db_var('channels')},$channel;
		$self->store_db;
	}
}

sub cmd_addchan {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $chanadd = $channel;
	if ($args =~ /^([[:graph:]]+)/) { $chanadd = $1; }
	if ($chanadd !~ /^\#/) { $chanadd = "#$chanadd"; }
	if (!$channel) { $channel = $sender; }
	if (!$chanadd) { $irc->yield(privmsg => $channel => "No channel specified") and return; }
	if (grep {lc $chanadd eq lc $_} @{$self->db_var('channels')}) {
		$self->print_debug("$sender added $chanadd to autojoin but channel is already there.");
		$irc->yield(privmsg => $channel => "Channel $chanadd already in autojoin list.");
	}
	else {
		$self->print_debug("$sender added $chanadd to autojoin.");
		$irc->yield(privmsg => $channel => "Added $chanadd to autojoin list.");
		push @{$self->db_var('channels')},$chanadd;
		$self->store_db;
	}
}

sub cmd_delchan {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $chandel = $channel;
	if ($args =~ /^([[:graph:]]+)/) { $chandel = $1; }
	if ($chandel !~ /^\#/) { $chandel = "#$chandel"; }
	if (!$channel) { $channel = $sender; }
	if (!$chandel) { $irc->yield(privmsg => $channel => "No channel specified") and return; }
	if (grep {lc $chandel eq lc $_} @{$self->db_var('channels')}) {
		$self->print_debug("$sender removed $chandel from autojoin.");
		$irc->yield(privmsg => $channel => "Removed $chandel from autojoin list.");
		my @tempchans = grep { lc $_ ne lc $chandel } @{$self->db_var('channels')};
		$self->db_var('channels', \@tempchans);
		$self->store_db;
	}
	else {
		$self->print_debug("$sender removed $chandel from autojoin, but channel is not in autojoin.");
		$irc->yield(privmsg => $channel => "Channel $chandel is not in autojoin list.");
	}
}

sub cmd_earmuffs {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	my $set = '+d';
	$set = '-d' unless $channel;
	$channel = $sender unless $channel;
	$set = '+d' if $args eq 'on';
	
	if ($set eq '+d') {
		$self->print_debug("Earmuff mode enabled by $sender");
		$irc->yield(privmsg => $channel => "Turning on earmuff mode. PM me 'earmuffs' to turn it off.");
	} else {
		$self->print_debug("Earmuff mode disabled by $sender");
		$irc->yield(privmsg => $channel => "Turning off earmuff mode. I can now receive channel messages.");
	}
	
	my $nick = $self->config_var('nick');
	$irc->yield(mode => "$nick $set");
}

sub cmd_addpath {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)[[:space:]]+"([[:print:]]+?)"[[:space:]]+([[:print:]]+)$/) {
		my $inst = $1;
		my $song = $2;
		my $path = $3;
		$self->print_debug("$sender attempted to add path for $song on $inst: $path");
#		if (exists $paths->{lc $inst}) {
#			if (exists $paths->{lc $inst}{lc $song}) {
#				$irc->yield(privmsg => $channel => "Path exists for $song on $inst. Please use ~updatepath to modify.");
#			}
#			else {
#				$paths->{lc $inst}{lc $song} = Paper::strip_xml($path);
#				$irc->yield(privmsg => $channel => "Path added for $song on $inst.");
#			}
#		}
#		else {
#			my @pathtypes = keys %{$paths};
#			$irc->yield(privmsg => $channel => "I only have paths for: @pathtypes");
#		}
	}
	else { $irc->yield(privmsg => $channel => "Syntax: ~addpath instrument \"song name\" path"); }
}

sub cmd_delpath {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)[[:space:]]+"?([[:print:]]+?)"?[[:space:]]*$/) {
		my $inst = $1;
		my $song = $2;
		$self->print_debug("$sender attempted to delete path for $song on $inst");
#		if (exists $paths->{lc $inst}) {
#			if (exists $paths->{lc $inst}{lc $song}) {
#				delete $paths->{lc $inst}{lc $song};
#				$irc->yield(privmsg => $channel => "Path for $song on $inst deleted.");
#			}
#			else {
#				$irc->yield(privmsg => $channel => "No path exists for $song on $inst.");
#			}
#		}
#		else {
#			my @pathtypes = keys %{$paths};
#			$irc->yield(privmsg => $channel => "I only have paths for: @pathtypes");
#		}
	}
	else { $irc->yield(privmsg => $channel => "Syntax: ~delpath instrument \"song name\""); }
}

sub cmd_updatepath {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)[[:space:]]+"([[:print:]]+?)"[[:space:]]+([[:print:]]+)$/) {
		my $inst = $1;
		my $song = $2;
		my $path = $3;
		$self->print_debug("$sender attempted to update path for $song on $inst: $path");
#		if (exists $paths->{lc $inst}) {
#			if (exists $paths->{lc $inst}{lc $song}) {
#				$paths->{lc $inst}{lc $song} = Paper::strip_xml($path);
#				$irc->yield(privmsg => $channel => "Path for $song on $inst updated.");
#			}
#			else {
#				$irc->yield(privmsg => $channel => "No path exists for $song on $inst.");
#			}
#		}
#		else {
#			my @pathtypes = keys %{$paths};
#			$irc->yield(privmsg => $channel => "I only have paths for: @pathtypes");
#		}
	}
	else { $irc->yield(privmsg => $channel => "Syntax: ~updatepath instrument \"song name\" path"); }
}

sub flatten_song {
	my $name = lc shift;
	$name =~ s/&/and/g;
	$name =~ s/[^\d\w]//g;
	return $name;
}

sub cmd_drumpath {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^"?([[:print:]]+?)"?( bns)?[[:space:]]*$/i) {
		my $origsong = $1;
		my $bns = 'rb2';
		my $bns_string = '';
		if (lc $2 eq ' bns') {
			$bns = 'bns';
			$bns_string = 'BNS ';
		}
	
		my $flatsong = flatten_song($origsong);
		my $url = "http://rockband.yajags.com/drumstats/" . $flatsong . "_expert_" . $bns . ".html";
		my $content = get($url);
		while (!defined $content and $url =~ s/the//) {
			$content = get($url);
		}
		my $song = $origsong;
		while (!defined $content and $song =~ s/\(.*\)//) {
			$flatsong = flatten_song($song);
			$url = "http://rockband.yajags.com/drumstats/" . $flatsong . "_expert_" . $bns . ".html";
			$content = get($url);
		}
		if (defined $content and $content =~ m|<div class="path">\n<h4>Path \(Shorthand\):</h4>\n([[:print:]]+?)\n</div>|) {
			my $path = $1;
			$path =~ s|</?span[[:print:]]*?>||g;
			$irc->yield(privmsg => $channel =>  $bns_string . "Path for \"$origsong\": $path");
		} else {
			$irc->yield(privmsg => $channel =>  "Unable to find path for \"$origsong\".");
		}
	}
}

sub cmd_voxpath { my $self = shift; return $self->cmd_path(@_[0..2],'vocals '.$_[3]); }
sub cmd_path {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	if ($args =~ /^([[:graph:]]+)[[:space:]]+"?([[:print:]]+?)"?[[:space:]]*$/) {
		my $inst = $1;
		my $song = $2;
		$self->print_debug("$sender requested path for $song on $inst");
#		if (exists $paths->{lc $inst}) {
#			if (exists $paths->{lc $inst}{lc $song}) {
#				my $path = $paths->{lc $inst}{lc $song};
#				$irc->yield(privmsg => $channel => "Path for $song on $inst: $path");
#			}
#			else {
#				$irc->yield(privmsg => $channel => "No path exists for $song on $inst.");
#			}
#		}
#		else {
#			my @pathtypes = keys %{$paths};
#			$irc->yield(privmsg => $channel => "I only have paths for: @pathtypes");
#		}
	}
	else { $irc->yield(privmsg => $channel => "Syntax: ~path instrument \"song name\""); }
}

sub cmd_setsong {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	return unless $channel;
	$self->print_debug("Song for $channel set to $args by $sender");
	if ($args eq '' or lc $args eq 'none') {
		$self->state_channel($channel, 'song', undef);
		$irc->yield(privmsg => $channel => "Song unset");
	} else {
		$self->state_channel($channel, 'song', $args);
		$irc->yield(privmsg => $channel => "Song set to $args");
	}
}

sub cmd_song {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	return unless $channel;
	$self->print_debug("Song for $channel requested by $sender");
	if ($self->state_channel_exists($channel) and defined $self->state_channel($channel, 'song')) {
		my $song = $self->state_channel($channel, 'song');
		$irc->yield(privmsg => $channel => "Current song: $song");
	} else {
		$irc->yield(privmsg => $channel => "No current song set.");
	}
}

sub cmd_genhelp {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	pod2html("--htmlroot=/var/www/html",
		"--htmldir=/var/www/html",
		"--infile=/home/grinnz/paper/paper.pod",
		"--outfile=/var/www/html/paper.html",
		"--title=Paperbot",
		"--header");
	$self->print_debug("Help file regenerated at request of $sender.");
	$irc->yield(privmsg => $channel => "Help file regenerated.");
}

sub cmd_uptime {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	$self->print_debug("Uptime requested by $sender");
	my $cpu_uptime = concise(duration_exact($self->sysinfo->get->{uptime}));
	my $bot_uptime = concise(duration_exact(time - $self->start_time));
	$irc->yield(privmsg => $channel => "Server Uptime: $cpu_uptime | Bot Uptime: $bot_uptime");
}

sub cmd_xkcd {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
}

sub cmd_locate {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $target = $sender;
	if ($args =~ /^([[:graph:]]+)/) {
		$target = $1;
	}
	if ($self->state_user_exists($target) or $target =~ /[.:]/) {
		$self->say_userinfo($irc, 'locate', $sender, $channel, $target);
	} else {
		$self->cmd_queue_info($irc,$sender,$channel,$target,'locate');
	}
}

sub cmd_weather {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	$args = $sender unless $args =~ /[[:graph:]]/;
	if ($args =~ /^([[:graph:]]+)/ and $self->state_user_exists($1)) {
		my $user = $1;
		my $host = $self->state_user($user, 'host');
		my $result = $self->resolver->resolve(
			type	=> 'A',
			host	=> $host,
			context	=> { irc => $irc, question => "$user ($host)", channel => $channel, sender => $sender, action => 'weather' },
			event	=> 'dns_response',
		);
		if (defined $result) {
			my @args;
			$args[ARG0] = $result;
			splice @args, 0, 1;
			$self->dns_response(@args);
		}
	} else {
		$self->say_userinfo($irc,'weather',$sender,$channel,$args);
	}
}

sub cmd_forecast {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	$args = $sender unless $args =~ /[[:graph:]]/;
	if ($args =~ /^([[:graph:]]+)/ and $self->state_user_exists($1)) {
		my $user = $1;
		my $host = $self->state_user($user, 'host');
		my $days;
		if ($args =~ /\b(\d)$/) {
			$days = $1;
		}
		my $result = $self->resolver->resolve(
			type	=> 'A',
			host	=> $host,
			context	=> { irc => $irc, question => "$user ($host)", channel => $channel, sender => $sender, action => 'forecast', days => $days },
			event	=> 'dns_response',
		);
		if (defined $result) {
			my @args;
			$args[ARG0] = $result;
			splice @args, 0, 1;
			$self->dns_response(@args);
		}
	} else {
		$self->say_userinfo($irc,'forecast',$sender,$channel,$args);
	}
}

sub cmd_convert {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	if ($args =~ /^\s*([-\d.e]+)\s*(.+)\s+(in|to|into)\s+(.+?)\s*$/i) {
		my ($input, $from_unit, $to_unit) = ($1, $2, $4);
		unless (looks_like_number($input)) {
			$irc->yield(privmsg => $channel => "Cannot convert non-number: $input");
			return;
		}
		
		my ($type, $result, $in_unit, $out_unit) = $self->do_conversion($input, $from_unit, $to_unit);
		
		unless (defined $type and defined $result) {
			$irc->yield(privmsg => $channel => "Cannot convert $from_unit to $to_unit");
			return;
		}
		
		$irc->yield(privmsg => $channel => "$type conversion: $input $in_unit = $result $out_unit");
	} else {
		$irc->yield(privmsg => $channel => "Usage: ~convert <num> <units> to <units>");
	}
}

my %si_prefix_value = (
	'y' => 1e-24,
	'yocto' => 1e-24,
	'z' => 1e-21,
	'zepto' => 1e-21,
	'a' => 1e-18,
	'atto' => 1e-18,
	'f' => 1e-15,
	'femto' => 1e-12,
	'p' => 1e-12,
	'pico' => 1e-12,
	'n' => 1e-9,
	'nano' => 1e-9,
	'u' => 1e-6,
	"\xB5" => 1e-6,
	"\x{03BC}" => 1e-6,
	'micro' => 1e-6,
	'm' => 1e-3,
	'milli' => 1e-3,
	'c' => 1e-2,
	'centi' => 1e-2,
	'd' => 1e-1,
	'deci' => 1e-1,
	'' => 1,
	'da' => 1e1,
	'deca' => 1e1,
	'h' => 1e2,
	'hecto' => 1e2,
	'k' => 1e3,
	'kilo' => 1e3,
	'M' => 1e6,
	'mega' => 1e6,
	'G' => 1e9,
	'giga' => 1e9,
	'T' => 1e12,
	'tera' => 1e12,
	'P' => 1e15,
	'peta' => 1e15,
	'E' => 1e18,
	'exa' => 1e18,
	'Z' => 1e21,
	'zetta' => 1e21,
	'Y' => 1e24,
	'yotta' => 1e24
);

my %distance_value = (
	'm' => 1,
	'meter' => 1,
	'yd' => 0.9144,
	'yard' => 0.9144,
	'in' => 0.0254,
	'inch' => 0.0254,
	'inche' => 0.0254,
	'"' => 0.0254,
	'ft' => 0.3048,
	'foot' => 0.3048,
	'feet' => 0.3048,
	'\'' => 0.3048,
	'mi' => 1609.344,
	'mile' => 1609.344,
	'fur' => 201.168,
	'furlong' => 201.168,
	'ftm' => 1.8288,
	'fathom' => 1.8288,
	'lea' => 4828.042,
	'league' => 4828.042,
	'pc' => 30.857e15,
	'parsec' => 30.857e15,
	'ly' => 9460730472580800,
	'lightyear' => 9460730472580800,
	'au' => 149597870700,
	'ua' => 149597870700,
	'a.u.' => 149597870700
);

my %byte_mag_value = (
	'' => 1,
	'K' => 1000,
	'M' => 1000**2,
	'G' => 1000**3,
	'T' => 1000**4,
	'P' => 1000**5,
	'E' => 1000**6,
	'Z' => 1000**7,
	'Y' => 1000**8,
	'Ki' => 1024,
	'Mi' => 1024**2,
	'Gi' => 1024**3,
	'Ti' => 1024**4,
	'Pi' => 1024**5,
	'Ei' => 1024**6,
	'Zi' => 1024**7,
	'Yi' => 1024**8
);

sub do_conversion {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($input, $from_unit, $to_unit) = @_;
	croak "Invalid parameters for conversion" unless defined $input and defined $from_unit and defined $to_unit;
	
	my ($type, $result, $in_unit, $out_unit);
	
	# Temperature
	my $temp_regex = qr/^(\xBA|\xB0|deg|degrees)?\s*(C|F|K|R|Celsius|Fahrenheit|Kelvin|Rankine)$/i;		
	if ($from_unit =~ $temp_regex) {
		my $from_scale = uc substr($2, 0, 1);
		if ($to_unit =~ $temp_regex) {
			my $to_scale = uc substr($2, 0, 1);
			$type = 'Temperature';
			$in_unit = ($from_scale eq 'K') ? $from_scale : "\xB0$from_scale";
			$out_unit = ($to_scale eq 'K') ? $to_scale : "\xB0$to_scale";
			$self->print_debug("Attempting to convert temperature $input $in_unit to $out_unit");
			$result = convert_temperature($input, $from_scale, $to_scale);
		}
	}
	
	return ($type, $result, $in_unit, $out_unit) if defined $result;
	
	# Bytes (decimal)
	my $byte_regex = qr/^((|K|M|G|T|P|E|Z|Y|kilo|mega|giga|tera|peta|exa|zetta|yotta)|(Ki|Mi|Gi|Ti|Pi|Ei|Zi|Yi|kibi|mebi|gibi|tebi|pebi|exbi|zebi|yobi))(B|byte|bit)$/i;
	if ($from_unit =~ $byte_regex) {
		my ($from_mag_dec, $from_mag_bin, $from_size) = ($2,$3,$4);
		if ($to_unit =~ $byte_regex) {
			my ($to_mag_dec, $to_mag_bin, $to_size) = ($2,$3,$4);
		    $type = 'Byte';
		    $from_size = ($from_size eq 'b' or lc $from_size eq 'bit') ? 'b' : 'B';
		    my $from_mag = (defined $from_mag_bin and length $from_mag_bin) ?
		    	uc(substr($from_mag_bin, 0, 1)) . 'i' : uc(substr($from_mag_dec, 0, 1));
			$in_unit = ($from_mag eq 'K') ? lc($from_mag) . $from_size : $from_mag . $from_size;
			
			$to_size = ($to_size eq 'b' or lc $to_size eq 'bit') ? 'b' : 'B';
		    my $to_mag = (defined $to_mag_bin and length $to_mag_bin) ?
		    	uc(substr($to_mag_bin, 0, 1)) . 'i' : uc(substr($to_mag_dec, 0, 1));
			$out_unit = ($to_mag eq 'K') ? lc($to_mag) . $to_size : $to_mag . $to_size;
			
			$self->print_debug("Attempting to convert bytes $input $in_unit to $out_unit");
			
			$result = convert_bytes($input, $from_mag, $to_mag, $from_size, $to_size);
		}
	}
	
	# Distance
	if ($from_unit =~ /^(.+?)(m(eter)?)?s?$/i and (exists $distance_value{$1} or
	    (defined $2 and length $2 and exists $si_prefix_value{$1}))) {
	    my ($from_si_prefix, $from_size);
		if (defined $2 and length $2) {
			$from_si_prefix = $1;
			$from_size = 'm';
		} else {
			$from_si_prefix = '';
			$from_size = $1;
		}
		if ($to_unit =~ /^(.+?)(m(eter)?)?s?$/i and (exists $distance_value{$1} or
		    (defined $2 and length $2 and exists $si_prefix_value{$1}))) {
		    $type = 'Distance';
			my ($to_si_prefix, $to_size);
			if (defined $2 and length $2) {
				$to_si_prefix = $1;
				$to_size = 'm';
			} else {
				$to_si_prefix = '';
				$to_size = $1;
			}
			
			$in_unit = $from_si_prefix . $from_size;
			$out_unit = $to_si_prefix . $to_size;
			
			$self->print_debug("Attemping to convert distance $input $in_unit to $out_unit");
			
			$result = convert_distance($input, $from_si_prefix, $to_si_prefix, $from_size, $to_size);
		}
	}
	
	return ($type, $result, $in_unit, $out_unit) if defined $result;
	
	return undef;
}

sub convert_temperature {
	my ($input, $from_scale, $to_scale) = @_;
	croak "Invalid parameters" unless defined $input and defined $from_scale and defined $to_scale;
	my $result;
	if ($from_scale eq $to_scale) {
		$result = $input;
	} elsif ($from_scale eq 'C' and $to_scale eq 'F') {
		$result = ($input*9/5)+32;
	} elsif ($from_scale eq 'C' and $to_scale eq 'K') {
		$result = $input+273.15;
	} elsif ($from_scale eq 'C' and $to_scale eq 'R') {
		$result = ($input+273.15)*9/5;
	} elsif ($from_scale eq 'F' and $to_scale eq 'C') {
		$result = ($input-32)*5/9;
	} elsif ($from_scale eq 'F' and $to_scale eq 'K') {
		$result = ($input+459.67)*5/9;
	} elsif ($from_scale eq 'F' and $to_scale eq 'R') {
		$result = $input+459.67;
	} elsif ($from_scale eq 'K' and $to_scale eq 'C') {
		$result = $input-273.15;
	} elsif ($from_scale eq 'K' and $to_scale eq 'F') {
		$result = ($input*9/5)-459.67;
	} elsif ($from_scale eq 'K' and $to_scale eq 'R') {
		$result = $input*9/5;
	} elsif ($from_scale eq 'R' and $to_scale eq 'C') {
		$result = ($input-491.67)*5/9;
	} elsif ($from_scale eq 'R' and $to_scale eq 'F') {
		$result = $input-459.67;
	} elsif ($from_scale eq 'R' and $to_scale eq 'K') {
		$result = $input*5/9;
	}
	return $result;
}

sub convert_bytes {
	my ($input, $from_mag, $to_mag, $from_size, $to_size) = @_;
	croak "Invalid input parameters" unless defined $input and defined $from_mag and defined $to_mag;
	$from_size = $to_size = 'B' unless defined $from_size and defined $to_size;
	
	my $result;
	
	my $size_multi = 1;
	if ($from_size eq 'b' and $to_size eq 'B') { $size_multi = 1/8; }
	elsif ($from_size eq 'B' and $to_size eq 'b') { $size_multi = 8; }
	
	if (exists $byte_mag_value{$from_mag} and exists $byte_mag_value{$to_mag}) {
		my $from_mag_value = $byte_mag_value{$from_mag};
		my $to_mag_value = $byte_mag_value{$to_mag};
		my $mag_multi = $from_mag_value / $to_mag_value;
		
		$result = $input * $mag_multi * $size_multi;
	}
	
	return $result;
}

sub convert_distance {
	my ($input, $from_si_prefix, $to_si_prefix, $from_size, $to_size) = @_;
	croak "Invalid input parameters" unless defined $input and defined $from_si_prefix and defined $to_si_prefix and defined $from_size and defined $to_size;
	
	my $result;
	my $si_multi = 1;
	if (exists $si_prefix_value{$from_si_prefix} and exists $si_prefix_value{$to_si_prefix}) {
		$si_multi = $si_prefix_value{$from_si_prefix} / $si_prefix_value{$to_si_prefix};
	}

	my $size_multi = 1;
	if (exists $distance_value{$from_size} and exists $distance_value{$to_size}) {
		$size_multi = $distance_value{$from_size} / $distance_value{$to_size};
	}

	$result = $input * $si_multi * $size_multi;
	
	return $result;
}

my %lang_name_to_code = (
	'arabic' => 'ar',
	'bulgarian' => 'bg',
	'catalan' => 'ca',
	'chinese (simplified)' => 'zh-CHS',
	'chinese (traditional)' => 'zh-CHT',
	'chinese' => 'zh-CHS',
	'czech' => 'cs',
	'danish' => 'da',
	'dutch' => 'nl',
	'english' => 'en',
	'estonian' => 'et',
	'finnish' => 'fi',
	'french' => 'fr',
	'german' => 'de',
	'greek' => 'el',
	'haitian creole' => 'ht',
	'haitian' => 'ht',
	'creole' => 'ht',
	'hebrew' => 'he',
	'hindi' => 'hi',
	'hmong daw' => 'mww',
	'hungarian' => 'hu',
	'indonesian' => 'id',
	'italian' => 'it',
	'japanese' => 'ja',
	'korean' => 'ko',
	'latvian' => 'lv',
	'lithuanian' => 'lt',
	'malay' => 'ms',
	'norwegian' => 'no',
	'persian (farsi)' => 'fa',
	'persian' => 'fa',
	'farsi' => 'fa',
	'polish' => 'pl',
	'portuguese' => 'pt',
	'romanian' => 'ro',
	'russian' => 'ru',
	'slovak' => 'sk',
	'slovenian' => 'sl',
	'spanish' => 'es',
	'swedish' => 'sv',
	'thai' => 'th',
	'turkish' => 'tr',
	'ukrainian' => 'uk',
	'urdu' => 'ur',
	'vietnamese' => 'vi'
);

my %lang_code_to_name = (
	'ar' => 'Arabic',
	'bg' => 'Bulgarian',
	'ca' => 'Catalan',
	'zh-chs' => 'Chinese (Simplified)',
	'zh-cht' => 'Chinese (Traditional)',
	'cs' => 'Czech',
	'da' => 'Danish',
	'nl' => 'Dutch',
	'en' => 'English',
	'et' => 'Estonian',
	'fi' => 'Finnish',
	'fr' => 'French',
	'de' => 'German',
	'el' => 'Greek',
	'ht' => 'Haitian Creole',
	'he' => 'Hebrew',
	'hi' => 'Hindi',
	'mww' => 'Hmong Daw',
	'hu' => 'Hungarian',
	'id' => 'Indonesian',
	'it' => 'Italian',
	'ja' => 'Japanese',
	'ko' => 'Korean',
	'lv' => 'Latvian',
	'lt' => 'Lithuanian',
	'ms' => 'Malay',
	'no' => 'Norwegian',
	'fa' => 'Persian (Farsi)',
	'pl' => 'Polish',
	'pt' => 'Portuguese',
	'ro' => 'Romanian',
	'ru' => 'Russian',
	'sk' => 'Slovak',
	'sl' => 'Slovenian',
	'es' => 'Spanish',
	'sv' => 'Swedish',
	'th' => 'Thai',
	'tr' => 'Turkish',
	'uk' => 'Ukrainian',
	'ur' => 'Urdu',
	'vi' => 'Vietnamese'
);

sub translator_lang_code_exists {
	my $code = shift;
	return undef unless defined $code;
	return exists $lang_code_to_name{lc $code};
}

sub translator_lang_name_exists {
	my $name = shift;
	return undef unless defined $name;
	return exists $lang_name_to_code{lc $name};
}

sub translator_lang_code_to_name {
	my $code = shift;
	return undef unless defined $code and exists $lang_code_to_name{lc $code};
	return $lang_code_to_name{lc $code};
}

sub translator_lang_name_to_code {
	my $name = shift;
	return undef unless defined $name and exists $lang_name_to_code{lc $name};
	return $lang_name_to_code{lc $name};
}

sub cmd_translate {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $phrase;
	my $from;
	my $to = 'en';
	if ($args =~ /^\s*("|')(.+?)\1\s+from\s+(.+?)(\s+to\s+(.+?))?\s*$/i) {
		$phrase = $2;
		$from = $3;
		$to = $5 if defined $5 and length $5;
	} elsif ($args =~ /^\s*("|')(.+?)\1\s+to\s+(.+?)(\s+from\s+(.+?))?\s*$/i) {
		$phrase = $2;
		$to = $3;
		$from = $5 if defined $5 and length $5;
	} elsif ($args =~ /^\s*("|')(.+?)\1/i) {
		$phrase = $2;
	} elsif ($args =~ /^(.+?)\s+from\s+(.+?)(\s+to\s+(.+?))?\s*$/i) {
		$phrase = $1;
		$from = $2;
		$to = $4 if defined $4 and length $4;
	} elsif ($args =~ /^(.+?)\s+to\s+(.+?)(\s+from\s+(.+?))?\s*$/i) {
		$phrase = $1;
		$to = $2;
		$from = $4 if defined $4 and length $4;
	} else {
		$phrase = $args;
	}
	
	unless (defined $from) {
		my $detected = $self->translate_detect($phrase);
		if (defined $detected) {
			$from = $detected;
		} else {
			$irc->yield(privmsg => $channel => "Unable to detect language of \"$phrase\"");
			return;
		}
	}
	
	my ($from_code, $to_code);
	if (translator_lang_code_exists($from)) {
		$from_code = $from;
	} elsif (my $code = translator_lang_name_to_code($from)) {
		$from_code = $code;
	} else {
		$irc->yield(privmsg => $channel => "Unknown language \"$from\"");
		return;
	}
	if (translator_lang_code_exists($to)) {
		$to_code = $to;
	} elsif (my $code = translator_lang_name_to_code($to)) {
		$to_code = $code;
	} else {
		$irc->yield(privmsg => $channel => "Unknown language \"$to\"");
		return;
	}
	
	my $from_name = translator_lang_code_to_name($from_code) // '';
	my $to_name = translator_lang_code_to_name($to_code) // '';
	
	$self->print_debug("Attempting to translate \"$phrase\" from $from_code to $to_code");
	
	my $translated_phrase = $self->translate($phrase, $from_code, $to_code);
	if (defined $translated_phrase) {
		$self->print_debug("Translation: $translated_phrase");
		$irc->yield(privmsg => $channel => "Translated from $from_name to $to_name: $translated_phrase");
	} else {
		$irc->yield(privmsg => $channel => "Error translating phrase");
	}
}

sub cmd_speak {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $phrase;
	my $lang;
	if ($args =~ /^\s*("|')(.+?)\1\s+(as|in)\s+(.+?)\s*$/i) {
		$phrase = $2;
		$lang = $4;
	} elsif ($args =~ /^\s*("|')(.+?)\1/i) {
		$phrase = $2;
	} elsif ($args =~ /^(.+?)\s+(as|in)\s+(.+?)\s*$/i) {
		$phrase = $1;
		$lang = $3;
	} else {
		$phrase = $args;
	}
	
	unless (defined $lang) {
		my $detected = $self->translate_detect($phrase);
		if (defined $detected) {
			$lang = $detected;
		} else {
			$irc->yield(privmsg => $channel => "Unable to detect language of \"$phrase\"");
			return;
		}
	}
	
	my $lang_code;
	if (translator_lang_code_exists($lang)) {
		$lang_code = $lang;
	} elsif (my $code = translator_lang_name_to_code($lang)) {
		$lang_code = $code;
	} else {
		$irc->yield(privmsg => $channel => "Unknown language \"$lang\"");
		return;
	}

	my $lang_name = translator_lang_code_to_name($lang_code) // '';
	
	$self->print_debug("Attempting to speak \"$phrase\" in $lang_code");
	
	my $spoken_url = $self->translate_speak($phrase, $lang_code);
	if (defined $spoken_url) {
		$self->print_debug("Spoken phrase: $spoken_url");
		$irc->yield(privmsg => $channel => "Phrase spoken in $lang_name: $spoken_url");
	} else {
		$irc->yield(privmsg => $channel => "Error retrieving spoken phrase");
	}
}

sub cmd_twitter {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $tweet;
	if ($args =~ /^\s*(\#\s*)?(\d+)\s*$/) {
		my $id = $2;
		$tweet = $self->search_twitter_id($id);
		
		unless (defined $tweet) {
			$irc->yield(privmsg => $channel => "Unable to retrieve tweet");
			return;
		}
	} elsif ($args =~ /^\s*\@([[:graph:]]+)\s*$/) {
		my $user = $1;
		$tweet = $self->search_twitter_user($user);
		
		unless (defined $tweet) {
			$irc->yield(privmsg => $channel => "No results for \"\@$args\"");
			return;
		}
	} else {
		if (defined $args and length $args) {
			my $tweets = $self->search_twitter($args);
			
			if (defined $tweets and @$tweets) {
				$self->cache_search_results('twitter', $tweets);
			} else {
				$irc->yield(privmsg => $channel => "No results for \"$args\"");
				return;
			}
		}
		
		$tweet = $self->cache_search_next('twitter');
	}
	
	if (defined $tweet) {
		my $username = $tweet->{'user'}{'screen_name'};
		my $content = $tweet->{'text'};
		$self->print_debug("Tweet by $username: $content");
		unless (defined $username and defined $content) {
			$irc->yield(privmsg => $channel => "Invalid tweet information");
			return;
		}
		
		my $id = $tweet->{'id'};
		my $base_url = "https://twitter.com";
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
		$irc->yield(privmsg => $channel => "Twitter result: Posted by $name ($b_code\@$username$b_code) $ago$in_reply_to: $content [ $url ]");
	} else {
		$irc->yield(privmsg => $channel => "No more results");
	}
}

sub cmd_wolframalpha {
	my $self = shift;
	my ($irc,$sender,$channel,$args) = @_;
	$channel = $sender unless $channel;
	
	my $query = $args;
	
	if ($self->state_user_exists($sender)) {
		my $host = $self->state_user($sender, 'host');
		my $result = $self->resolver->resolve(
			type	=> 'A',
			host	=> $host,
			context	=> { irc => $irc, question => "$sender ($host)", channel => $channel, sender => $sender, action => 'wolframalpha', query => $query },
			event	=> 'dns_response',
		);
		if (defined $result) {
			my @args;
			$args[ARG0] = $result;
			splice @args, 0, 1;
			$self->dns_response(@args);
		}
	} else {
		if (!$self->queue_whois_exists($sender)) {
			$self->queue_whois($sender, $channel, 'wolframalpha', $sender, $query);
			$irc->yield(whois => $sender);
		}
		else {
			$irc->yield(privmsg => $channel => "$sender: Please repeat command in a few seconds.");
		}
	}
}

sub do_wolframalpha_query {
	my $self = shift;
	my ($irc,$sender,$channel,$query,$address) = @_;
	$channel = $sender unless $channel;
	
	my $response = $self->search_wolframalpha($query, $address);
	if (defined $response) {
		my $result = $response->documentElement->findnodes("/queryresult")->shift;
		my $success = $result->getAttribute('success');
		my $error = $result->getAttribute('error');
		if (defined $success and $success eq 'false') {
			if (defined $error and $error eq 'true') {
				my $err_msg = $result->findnodes("error/msg")->shift->textContent;
				$irc->yield(privmsg => $channel => "Error querying Wolfram Alpha: $err_msg");
				return;
			}
			my @warning_output;
			my $languagemsg = $result->findnodes("languagemsg")->shift;
			if (defined $languagemsg) {
				my $msg = $languagemsg->getAttribute('english');
				push @warning_output, "Language error: $msg";
			}
			my $tips = $result->findnodes("tips")->shift;
			if (defined $tips) {
				my $tips_list = $tips->findnodes("tip");
				my $tips_str = join '; ', map { $_->getAttribute('text') } $tips_list->get_nodelist;
				push @warning_output, "Query not understood: $tips_str";
			}
			my $didyoumeans = $result->findnodes("didyoumeans")->shift;
			if (defined $didyoumeans) {
				my $didyoumean_list = $didyoumeans->findnodes("didyoumean");
				my $didyoumean_str = join '; ', map { $_->textContent } $didyoumean_list->get_nodelist;
				push @warning_output, "Did you mean: $didyoumean_str";
			}
			my $futuretopic = $result->findnodes("futuretopic")->shift;
			if (defined $futuretopic) {
				my $topic = $futuretopic->getAttribute('topic');
				my $msg = $futuretopic->getAttribute('msg');
				push @warning_output, "$topic: $msg";
			}
			my $relatedexamples = $result->findnodes("relatedexamples")->shift;
			if (defined $relatedexamples) {
				my $example_list = $relatedexamples->findnodes("relatedexample");
				my $example_str = join '; ', map { $_->getAttribute('category') } $example_list->get_nodelist;
				push @warning_output, "Related categories: $example_str";
			}
			my $examplepage = $result->findnodes("examplepage")->shift;
			if (defined $examplepage) {
				my $category = $examplepage->getAttribute('category');
				my $url = $examplepage->getAttribute('url');
				push @warning_output, "See category $category: $url";
			}
			if (@warning_output) {
				$irc->yield(privmsg => $channel => join(' || ', @warning_output));
			} else {
				$irc->yield(privmsg => $channel => "Query was unsuccessful");
			}
		} else {
			my @pod_contents;
			my $pods = $result->findnodes("pod");
			foreach my $pod ($pods->get_nodelist) {
				my $title = $pod->getAttribute('title');
				my @contents;
				my $subpods = $pod->findnodes("subpod");
				foreach my $subpod ($subpods->get_nodelist) {
					my $subtitle = $subpod->getAttribute('title');
					my $plaintext = $subpod->findnodes("plaintext");
					next unless defined $plaintext and $plaintext->size;
					my $content = $plaintext->shift->textContent;
					next unless defined $content and length $content;
					$content =~ s/ \| / - /g;
					$content =~ s/^\r?\n//;
					$content =~ s/\r?\n$//;
					$content =~ s/\r?\n/, /g;
					$content =~ s/\\\:([0-9a-f]{4})/chr(hex($1))/egi;
					$content =~ s/~~/\x{2248}/g;
					if (defined $subtitle and length $subtitle) {
						$content = "$subtitle: $content";
					}
					push @contents, $content;
				}
				
				if (@contents) {
					my $pod_text = "$title: " . join '; ', @contents;
					push @pod_contents, $pod_text;
				}
			}
			
			if (@pod_contents) {
				my $output = join ' || ', @pod_contents;
				
				$self->print_debug("Response: $output");
				$irc->yield(privmsg => $channel => $output);
			} else {
				$self->print_debug("No response");
				$irc->yield(privmsg => $channel => "No output from Wolfram|Alpha query");
			}
		}
	} else {
		$irc->yield(privmsg => $channel => "Error querying Wolfram Alpha");
	}
}

1;
