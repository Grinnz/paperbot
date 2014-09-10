package Paper;

use strict;
use warnings;
use Carp;
use Exporter qw/import/;
use Data::Dumper;
use File::Path qw/make_path/;
use Tie::File;
use Storable;
use IO::Select;
use POE qw/Component::IRC Component::IRC::Plugin::CTCP Component::Client::DNS/;

use Text::Aspell;
use REST::Google::Search::Web;
use REST::Google::Search::Images;
use Sys::Statistics::Linux::SysInfo;
use GeoIP2::Database::Reader;
use Geo::METAR;
use XML::Atom::Entry;
use XML::Atom::Feed;
use XML::LibXML;
use LWP::Simple;
use LWP::UserAgent;
use URI::Escape;
use HTML::Entities;
use JSON::XS;
use Digest::MD5 qw/md5_hex/;
use Data::Validate::IP qw/is_ipv4 is_ipv6/;
use MIME::Base64;
use DBI;

use Paper::IRC;
use Paper::Commands;

use version; our $VERSION = version->declare('v1.3.1');

use constant {
	IRC_SOCIALGAMER => 1,
	IRC_GAMESURGE => 2,
	IRC_FREENODE => 3
};

use constant QUEUE_TIMEOUT => 60;
use constant CACHE_WEATHER_EXPIRATION => 600;

use constant XKCD_CHECK_INTERVAL => 600;
use constant XKCD_CHECK_EXPIRE => 3600 * 24 * 7;
use constant XKCD_CHECK_LIMIT => 10;

use constant DEFAULT_CONFIG => {
	debug => 1,
	echo  => 1,
	catchtube => 1,
	server => 'irc.socialgamer.net',
	serverpass => '',
	nick => 'Paper',
	username => 'Paperbot',
	ircname => 'Paperbot',
	password => '',
	flood => 1,
	awaymsg => 'I am a bot. Say ~help in a channel or in PM for help.',
	googlekey => '',
	youtubeid => '',
	youtubekey => '',
	spellmode => 'fast',
	ssl => 0,
	port => 6667,
	master => 'Grinnz',
	geoip2file => '/usr/local/share/GeoIP/GeoLite2-City.mmdb'
};

use constant DEFAULT_DB => {
	'channels' => [],
	'admins' => [],
	'voices' => [],
	'todo' => []
};

BEGIN {
	REST::Google::Search::Web->http_referer('http://grinnz.com');
	REST::Google::Search::Images->http_referer('http://grinnz.com');
}

our @EXPORT = qw/IRC_SOCIALGAMER IRC_GAMESURGE IRC_FREENODE/;

my $paper;

sub singleton {
	return $paper if $paper;
	my $class = shift;
	return $class->new(@_);
}

sub new {
	my $class = shift;
	my ($confdir, $irctype) = @_;
	
	my $home = $ENV{'HOME'} // '~';
	$confdir = "$home/.paperbot" unless defined $confdir;
	
	make_path($confdir);
	
	$irctype = IRC_SOCIALGAMER unless defined $irctype;
	my $ircclass;
	if ($irctype == IRC_SOCIALGAMER) {
		$ircclass = 'Paper::IRC::SocialGamer';
	} elsif ($irctype == IRC_GAMESURGE) {
		$ircclass = 'Paper::IRC::GameSurge';
	} elsif ($irctype == IRC_FREENODE) {
		$ircclass = 'Paper::IRC::Freenode';
	}
	eval "require $ircclass";
	$ircclass->import;
	
	my $version = $VERSION->stringify;
	
	my $self = {};
	$self->{'config'} = DEFAULT_CONFIG;
	$self->{'db'} = DEFAULT_DB;
	$self->{'quotes'} = [];
	$self->{'config_file'} = "$confdir/paperbot.conf";
	$self->{'db_file'} = "$confdir/paperbot.db";
	$self->{'quote_file'} = "$confdir/quotes.txt";
	$self->{'state'} = { 'users' => {}, 'channels' => {}, 'nicks' => {} };
	$self->{'queue'} = { 'invites' => {}, 'cmds' => {}, 'topic' => {}, 'whois' => {} };
	$self->{'cache'} = { 'quote' => {}, 'quoten' => {}, 'google' => {}, 'youtube' => {} };
	$self->{'child_pids'} = {};
	$self->{'version'} = $version;
	bless $self, $class;
	
	$paper = $self;
	
	return $self;
}

sub init_irc {
	my $self = shift;
	
	$self->load_config;
	$self->load_db;
	$self->load_quotes;
	
	my $version = $self->{'version'};
	my $master = $self->config_var('master');
	my $ircname = "Paperbot $version";
	$ircname .= " by $master" if defined $master;
	
	unless ($ircname eq $self->config_var('ircname')) {
		$self->config_var('ircname', $ircname);
		$self->store_config_var('ircname');
	}
	
	$self->nick($self->config_var('nick'));
	
	$self->irc or return undef;

	return $self;
}

# === Event methods ===

sub _start {
	my $self = $_[OBJECT];
	my $heap = $_[HEAP];
	my $irc = $heap->{irc};
	my $kernel = $_[KERNEL];
	
	my $ircname = $self->config_var('ircname') // DEFAULT_CONFIG->{'ircname'};

	$irc->plugin_add( 'CTCP' => POE::Component::IRC::Plugin::CTCP->new(
		userinfo => $ircname
	));

	$irc->yield( register => 'all' );
	
	my $server = $self->config_var('server');
	my $port = $self->config_var('port');
	$self->print_debug("Starting connection to $server/$port...");
	$self->start_time(time);
	$irc->yield( connect => {} );
	
	$kernel->sig(TERM => 'sig_terminate');
	$kernel->sig(QUIT => 'sig_terminate');
	$kernel->sig(INT => 'sig_terminate');
	
	$kernel->yield('check_xkcd');
	
	#$self->get_translator_languages;
	
	return;
}

sub _default {
	my $self = $_[OBJECT];
	my ($event,$args) = @_[ARG0 .. $#_];
	my @output = "$event: ";
	foreach my $arg (@$args) {
		if (ref $arg eq 'ARRAY') {
			push @output, '[' . join(', ', @$arg) . ']';
		} else {
			push @output, "'$arg'";
		}
	}
	$self->print_debug(join ' ', @output);
	return 0;
}

sub sig_terminate {
	my $self = $_[OBJECT];
	my $kernel = $_[KERNEL];
	my $signal = $_[ARG0];
	
	$self->print_debug("Received signal SIG$signal");
	
	$self->is_stopping(1);
	$self->end_sessions;
	$kernel->sig_handled;
}

sub dns_response {
	my $self = $_[OBJECT];
	my $result = $_[ARG0];
	if (defined $result) {
		my $irc = $result->{context}{irc};
		my $question = $result->{context}{question};
		my $sender = $result->{context}{sender};
		my $channel = $result->{context}{channel};
		my $action = $result->{context}{action};
		my $host = $result->{host};
		if (defined $result->{response}) {
			my $address;
			my $lookuptype = "DNS";
			foreach my $answer ($result->{response}->answer) {
				if ($answer->type eq "A" or $answer->type eq "AAAA") {
					$address = $answer->address;
					last;
				} elsif ($answer->type eq "PTR") {
					$address = $answer->ptrdname;
					$lookuptype = "RDNS";
					last;
				}
			}
			$address = $host unless defined $address;
			if ($action eq 'locate') {
				my $location = $self->lookup_geoip_location($address);
				if (defined $location) {
					$self->print_debug("GeoIP lookup of $address: $location");
					$irc->yield(privmsg => $channel => "$question appears to be located in: $location");
				} else {
					$self->print_debug("GeoIP lookup of $address: unknown");
					$irc->yield(privmsg => $channel => "Could not find location of $question");
				}
			} elsif ($action eq 'weather') {
				my $location = $self->lookup_geoip_weather($address);
				if (defined $location) {
					$self->print_debug("Finding weather for $address at $location");
					$self->say_userinfo($irc,'weather',$sender,$channel,$location);
				} else {
					$self->print_debug("Location of $address unknown");
					$irc->yield(privmsg => $channel => "Could not find location of $question");
				}
			} elsif ($action eq 'forecast') {
				my $location = $self->lookup_geoip_weather($address);
				if (defined $location) {
					my $days = $result->{context}{days};
					$location .= " $days" if defined $days;
					$self->print_debug("Finding forecast for $address at $location");
					$self->say_userinfo($irc,'forecast',$sender,$channel,$location);
				} else {
					$self->print_debug("Location of $address unknown");
					$irc->yield(privmsg => $channel => "Could not find location of $question");
				}
			} elsif ($action eq 'wolframalpha') {
				my $query = $result->{context}{query};
				$self->print_debug("Sending query to Wolfram Alpha with location IP $address");
				$self->do_wolframalpha_query($irc,$sender,$channel,$query,$address);
			} else {
				$irc->yield(privmsg => $channel => "$lookuptype lookup for $question: " . $address);
			}
		}
		else { $irc->yield(privmsg => $channel => "DNS lookup for $question: Failed"); }
	}
}

sub check_xkcd {
	my $self = $_[OBJECT];
	my $kernel = $_[KERNEL];
	
	$kernel->delay('check_xkcd', XKCD_CHECK_INTERVAL);
	
	my $latest_num = $self->update_xkcd // return undef;
	
	my $xkcd_queue = $self->{'queue'}{'xkcd'} //= {};
	delete $xkcd_queue->{$latest_num};
	foreach my $num (1..$latest_num-1) {
		my $xkcd = $self->cache_xkcd($num);
		unless ((defined $xkcd and $xkcd->{'timestamp'}>(time-&XKCD_CHECK_EXPIRE)) or exists $xkcd_queue->{$num}) {
			$xkcd_queue->{$num} = 1;
		}
	}
	
	my @to_check = (keys %$xkcd_queue)[0..XKCD_CHECK_LIMIT-1];
	foreach my $num (@to_check) {
		next unless defined $num;
		my $cached = $self->update_xkcd($num);
		delete $xkcd_queue->{$num};
	}
	
	$self->store_db;
}

# === Object accessors ===

sub is_stopping {
	my $self = shift;
	if (@_) {
		$self->{'is_stopping'} = 1;
	}
	return $self->{'is_stopping'};
}

sub nick {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	if (@_) {
		$self->{'nick'} = shift;
	}
	
	return $self->{'nick'};
}

sub config_var {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "Invalid method parameters" unless defined $name;
	
	if (@_) {
		my $value = shift;
		croak "Configuration values must be scalar" if ref $value;
		$self->{'config'}{$name} = $value;
		$self->store_config_var($name);
	}
	
	return undef unless exists $self->{'config'}{$name};
	return $self->{'config'}{$name};
}

sub db_var {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "Invalid method parameters" unless defined $name;
	
	if (@_) {
		my $value = shift;
		$self->{'db'}{$name} = $value;
		$self->store_db;
	}
	
	return undef unless exists $self->{'db'}{$name};
	return $self->{'db'}{$name};
}

sub irc {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'irc'}) {
		my $irc = POE::Component::IRC->spawn(
			'Nick' => $self->config_var('nick'),
			'Server' => $self->config_var('server'),
			'Port' => $self->config_var('port'),
			'Password' => $self->config_var('serverpass'),
			'Ircname' => $self->config_var('ircname'),
			'Username' => $self->config_var('username'),
			'UseSSL' => $self->config_var('ssl'),
			'Flood' => $self->config_var('flood'),
			'Resolver' => $self->resolver
		);
		warn "Unable to create IRC component: $!" and return undef unless $irc;
		$self->{'irc'} = $irc;
	}
	
	return $self->{'irc'};
}

sub lwp {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'lwp'}) {
		my $lwp = LWP::UserAgent->new;
		$self->{'lwp'} = $lwp;
	}
	
	return $self->{'lwp'};
}

sub xml {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'xml'}) {
		my $xml = XML::LibXML->new;
		$self->{'xml'} = $xml;
	}
	
	return $self->{'xml'};
}

sub resolver {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'resolver'}) {
		my $resolver = POE::Component::Client::DNS->spawn;
		warn "Unable to create DNS component: $!" and return undef unless $resolver;
		$self->{'resolver'} = $resolver;
	}
	
	return $self->{'resolver'};
}

sub io_select {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'io_select'}) {
		my $io_select = IO::Select->new;
		$self->{'io_select'} = $io_select;
	}
	
	return $self->{'io_select'};
}

sub child_handle {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $pid = shift;
	croak "No PID given" unless defined $pid;
	
	if (@_) {
		my $handle = shift;
		croak "No handle given" unless defined $handle;
		
		$self->{'child_pids'}{$pid} = $handle;
	}
	
	return undef unless exists $self->{'child_pids'}{$pid};
	return $self->{'child_pids'}{$pid};
}

sub child_handle_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $pid = shift;
	croak "No PID given" unless defined $pid;
	
	delete $self->{'child_pids'}{$pid};
	
	return 1;
}

sub pyx_dbh {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $dbhost = $self->config_var('pyx_dbhost');
	my $dbuser = $self->config_var('pyx_dbuser');
	my $dbpass = $self->config_var('pyx_dbpass');
	my $dbname = $self->config_var('pyx_dbname');
	warn "Missing PYX database configuration" and return undef
		unless defined $dbhost and defined $dbuser and defined $dbpass and defined $dbname;
	
	my $dbh = DBI->connect_cached("dbi:Pg:dbname=$dbname;host=$dbhost", $dbuser, $dbpass);
	#warn "Unable to connect to PYX database: ".$DBI::errstr."\n" and return undef unless defined $dbh;
	return undef unless defined $dbh;
	
	return $dbh;
}

sub speller {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $regen = shift;
	
	if ($regen or !defined $self->{'speller'}) {
		my $speller = Text::Aspell->new;
		return undef unless defined $speller;
		
		my $spellmode = $self->config_var('spellmode') // DEFAULT_CONFIG->{'spellmode'};
		
		$speller->set_option('lang','en_us');
		$speller->set_option('sug-mode',$spellmode);
		$speller->set_option('ignore-case','true');
		$speller->set_option('ignore-repl','false');
		$speller->create_speller;
		
		$self->{'speller'} = $speller;
	}
	
	return $self->{'speller'};
}

sub sysinfo {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'sysinfo'}) {
		my $sysinfo = Sys::Statistics::Linux::SysInfo->new('rawtime' => 1);
		$self->{'sysinfo'} = $sysinfo;
	}
	
	return $self->{'sysinfo'};
}

sub geoip {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'geoip'}) {
		my $geoipfile = $self->config_var('geoip2file');
		$self->print_debug("GeoIP2 database file configuration is missing") and return undef unless defined $geoipfile;
		my $geoip = eval { GeoIP2::Database::Reader->new(file => $geoipfile); };
		if ($@) {
			$self->print_debug("Error opening GeoIP2 database: $@");
			return undef;
		}
		$self->{'geoip'} = $geoip;
	}
	
	return $self->{'geoip'};
}

sub metar {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	unless (defined $self->{'metar'}) {
		my $metar = Geo::METAR->new;
		$self->{'metar'} = $metar;
	}
	
	return $self->{'metar'};
}

sub ms_access_token {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $scope = shift // "http://api.microsofttranslator.com";
	my $grant_type = shift // "client_credentials";
	
	unless (defined $self->{'ms_access_token'} and defined $self->{'ms_access_expire'} and $self->{'ms_access_expire'} > time) {
		my $lwp = $self->lwp;
		
		$self->print_debug("Requesting Microsoft API access token");
		
		my $access_uri = "https://datamarket.accesscontrol.windows.net/v2/OAuth2-13/";
		my $client_id = $self->config_var('msclientid');
		$self->print_debug("Microsoft Client ID is missing") and return undef unless defined $client_id;
		my $client_secret = $self->config_var('msclientsecret');
		$self->print_debug("Microsoft Client Secret is missing") and return undef unless defined $client_secret;
		my %params = (
			'client_id' => uri_escape($client_id),
			'client_secret' => uri_escape($client_secret),
			'scope' => $scope,
			'grant_type' => $grant_type
		);
		
		my $response = $lwp->post($access_uri, \%params);
		if ($response->is_success) {
			my $data = eval { decode_json($response->content); };
			warn $@ and return undef if $@;
			if (defined $data->{'access_token'}) {
				$self->{'ms_access_token'} = $data->{'access_token'};
				$self->{'ms_access_expire'} = time+$data->{'expires_in'};
			} else {
				$self->print_debug("No Microsoft access token returned");
				return undef;
			}
		} else {
			$self->print_debug("Error requesting Microsoft access token: ".$response->status_line);
			return undef;
		}
	}
	
	return $self->{'ms_access_token'};
}

sub twitter_access_token {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $grant_type = shift // "client_credentials";
	
	unless (defined $self->{'twitter_access_token'}) {
		my $lwp = $self->lwp;
		
		$self->print_debug("Requesting Twitter API access token");
		
		my $token_uri = "https://api.twitter.com/oauth2/token";
		my $twitter_key = $self->config_var('twitterkey');
		$self->print_debug("Twitter API Key is missing") and return undef unless defined $twitter_key;
		my $twitter_secret = $self->config_var('twittersecret');
		$self->print_debug("Twitter API Secret is missing") and return undef unless defined $twitter_secret;
		
		my $authorization_key = encode_base64(uri_escape($twitter_key) . ':' . uri_escape($twitter_secret), '');
		my $content_type = 'application/x-www-form-urlencoded;charset=UTF-8';
		my %params = ( 'grant_type' => $grant_type );
		
		my $response = $lwp->post($token_uri, \%params, 'Authorization' => "Basic $authorization_key", 'Content-Type' => $content_type);
		if ($response->is_success) {
			my $data = eval { decode_json($response->content); };
			warn $@ and return undef if $@;
			if (defined $data->{'access_token'}) {
				$self->{'twitter_access_token'} = $data->{'access_token'};
			} else {
				$self->print_debug("No Twitter access token returned");
				return undef;
			}
		} else {
			$self->print_debug("Error requesting Twitter access token: ".$response->status_line);
			return undef;
		}
	}
	
	return $self->{'twitter_access_token'};
}

sub start_time {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	if (@_) { $self->{'start_time'} = shift; }
	
	return $self->{'start_time'};
}

sub bot_version {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	return $self->{'version'};
}

# === State accessors ===

sub state_user {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No username given" unless defined $name;
	my $key = shift;
	croak "No key to retrieve" unless defined $key;
	
	my $users = $self->{'state'}{'users'};
	
	if (@_) {
		my $value = shift;
		$users->{lc $name} = {} unless defined $users->{lc $name};
		$users->{lc $name}{$key} = $value;
	}
	
	return undef unless exists $users->{lc $name} and exists $users->{lc $name}{$key};
	return $users->{lc $name}{$key};
}

sub state_user_copy {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $oldname = shift;
	croak "No current nickname given" unless defined $oldname;
	my $newname = shift;
	croak "No new nickname given" unless defined $newname;
	
	my $users = $self->{'state'}{'users'};
	
	$users->{lc $newname} = $users->{lc $oldname} if exists $users->{lc $oldname};
	
	return 1;
}

sub state_user_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No username given" unless defined $name;
	
	my $users = $self->{'state'}{'users'};
	
	return (exists $users->{lc $name}) ? 1 : undef;
}

sub state_user_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No username given" unless defined $name;
	
	my $users = $self->{'state'}{'users'};
	
	if (exists $users->{lc $name}) {
		$self->state_ident_delete($users->{lc $name}{'ident'}) if defined $users->{lc $name}{'ident'};
		$self->state_user_delete_channels($name);
		delete $users->{lc $name};
	}
	
	return 1;
}

sub state_user_list {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $users = $self->{'state'}{'users'};
	
	return keys %$users;
}

sub state_user_delete_channels {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No username given" unless defined $name;
	
	my $channels = $self->{'state'}{'channels'};
	
	foreach my $channel (keys %$channels) {
		$self->state_channel_user($channel, $name, undef);
	}
	
	return 1;
}

sub state_channel {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No channel name given" unless defined $name;
	my $key = shift;
	croak "No key to retrieve" unless defined $key;
	
	my $channels = $self->{'state'}{'channels'};
	
	if (@_) {
		my $value = shift;
		$channels->{lc $name} = {} unless defined $channels->{lc $name};
		$channels->{lc $name}{$key} = $value;
	}
	
	return undef unless exists $channels->{lc $name} and exists $channels->{lc $name}{$key};
	return $channels->{lc $name}{$key};
}

sub state_channel_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No channel name given" unless defined $name;
	
	my $channels = $self->{'state'}{'channels'};
	
	return (exists $channels->{lc $name}) ? 1 : undef;
}

sub state_channel_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No channel name given" unless defined $name;
	
	my $channels = $self->{'state'}{'channels'};
	
	delete $channels->{lc $name};
	
	return 1;
}

sub state_channel_user {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "No channel name given" unless defined $name;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $users = $self->state_channel($name, 'users');
	
	if (@_) {
		unless (defined $users) {
			$users = {};
			$self->state_channel($name, 'users', $users);
		}
		my $status = shift;
		if (defined $status) {
			$users->{lc $user} = $status;
		} else {
			delete $users->{lc $user};
		}
	}
	
	return undef unless defined $users and exists $users->{lc $user};
	return $users->{lc $user};
}

sub state_ident {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ident = shift;
	croak "No identification given" unless defined $ident;
	
	my $idents = $self->{'state'}{'idents'};
	
	if (@_) {
		my $nick = shift;
		$idents->{lc $ident} = $nick;
	}
	
	return undef unless exists $idents->{lc $ident};
	return $idents->{lc $ident};
}

sub state_ident_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ident = shift;
	croak "Not called as an object method" unless defined $ident;
	
	my $idents = $self->{'state'}{'idents'};
	
	delete $idents->{lc $ident};
	
	return 1;
}

# === Queue accessors ===

sub queue_cmd {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($user, $channel, $cmd, $args) = @_;
	croak "No user name given" unless defined $user;
	croak "No command name given" unless defined $cmd;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	$cmds->{lc $user} = { 'channel' => $channel, 'cmd' => $cmd, 'args' => $args, 'timestamp' => time };
	
	return $cmds->{lc $user};
}

sub queue_cmd_channel {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	return undef unless exists $cmds->{lc $user};
	return $cmds->{lc $user}{'channel'};
}

sub queue_cmd_command {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	return undef unless exists $cmds->{lc $user};
	return $cmds->{lc $user}{'cmd'};
}

sub queue_cmd_args {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	return undef unless exists $cmds->{lc $user};
	return $cmds->{lc $user}{'args'};
}

sub queue_cmd_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	if (exists $cmds->{lc $user} and time - $cmds->{lc $user}{'timestamp'} > QUEUE_TIMEOUT) {
		delete $cmds->{lc $user};
	}
	
	return (exists $cmds->{lc $user}) ? 1 : undef;
}

sub queue_cmd_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $cmds = $self->{'queue'}{'cmds'};
	
	delete $cmds->{lc $user};
	
	return 1;
}

sub queue_cmd_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'queue'}{'cmds'} = {};
	
	return 1;
}

sub queue_whois {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($user, $channel, $type, $sender, $args) = @_;
	croak "No user name given" unless defined $user;
	croak "No lookup type given" unless defined $type;
	croak "No lookup subject given" unless defined $sender;
	
	my $queue = $self->{'queue'}{'whois'};
	
	$queue->{lc $user} = { 'channel' => $channel, 'type' => $type, 'sender' => $sender, 'timestamp' => time, 'args' => $args };
	
	return $queue->{lc $user};
}

sub queue_whois_channel {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	return undef unless exists $queue->{lc $user};
	return $queue->{lc $user}{'channel'};
}

sub queue_whois_type {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	return undef unless exists $queue->{lc $user};
	return $queue->{lc $user}{'type'};
}

sub queue_whois_sender {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	return undef unless exists $queue->{lc $user};
	return $queue->{lc $user}{'sender'};
}

sub queue_whois_args {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	return undef unless exists $queue->{lc $user};
	return $queue->{lc $user}{'args'};
}

sub queue_whois_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	if (exists $queue->{lc $user} and time - $queue->{lc $user}{'timestamp'} > QUEUE_TIMEOUT) {
		delete $queue->{lc $user};
	}
	
	return (exists $queue->{lc $user}) ? 1 : undef;
}

sub queue_whois_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $queue = $self->{'queue'}{'whois'};
	
	delete $queue->{lc $user};
	
	return 1;
}

sub queue_whois_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'queue'}{'whois'} = {};
	
	return 1;
}

sub queue_invite {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	my $channel = shift;
	croak "No channel name given" unless defined $channel;
	
	my $invites = $self->{'queue'}{'invites'};
	
	my $step = 'whois';
	$invites->{lc $user} = { 'channel' => $channel, 'step' => $step, 'timestamp' => time };
	
	return $invites->{lc $user};
}

sub queue_invite_channel {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $invites = $self->{'queue'}{'invites'};
	
	return undef unless exists $invites->{lc $user};
	return $invites->{lc $user}{'channel'};
}

sub queue_invite_step {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $invites = $self->{'queue'}{'invites'};
	
	if (@_) {
		my $step = shift;
		$invites->{lc $user} = {} unless defined $invites->{lc $user};
		$invites->{lc $user}{'step'} = $step;
		$invites->{lc $user}{'timestamp'} = time;
	}
	
	return undef unless exists $invites->{lc $user};
	return $invites->{lc $user}{'step'};
}

sub queue_invite_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $invites = $self->{'queue'}{'invites'};
	
	if (exists $invites->{lc $user} and time - $invites->{lc $user}{'timestamp'} > QUEUE_TIMEOUT) {
		delete $invites->{lc $user};
	}
	
	return (exists $invites->{lc $user}) ? 1 : undef;
}

sub queue_invite_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "No user name given" unless defined $user;
	
	my $invites = $self->{'queue'}{'invites'};
	
	delete $invites->{lc $user};
	
	return 1;
}

sub queue_invite_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'queue'}{'invites'} = {};
	
	return 1;
}

sub queue_topic {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $channel = shift;
	croak "No channel name given" unless defined $channel;
	
	my $topicqueue = $self->{'queue'}{'topic'};
	
	my $step = 'ask';
	$topicqueue->{lc $channel} = { 'step' => $step, 'timestamp' => time };
	
	return $topicqueue->{lc $channel};
}

sub queue_topic_step {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $channel = shift;
	croak "No channel name given" unless defined $channel;
	
	my $topicqueue = $self->{'queue'}{'topic'};
	
	if (@_) {
		my $step = shift;
		$topicqueue->{lc $channel} = {} unless defined $topicqueue->{lc $channel};
		$topicqueue->{lc $channel}{'step'} = $step;
		$topicqueue->{lc $channel}{'timestamp'} = time;
	}
	
	return undef unless exists $topicqueue->{lc $channel};
	return $topicqueue->{lc $channel}{'step'};
}

sub queue_topic_exists {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $channel = shift;
	croak "No channel name given" unless defined $channel;
	
	my $topicqueue = $self->{'queue'}{'topic'};
	
	if (exists $topicqueue->{lc $channel} and time - $topicqueue->{lc $channel}{'timestamp'} > QUEUE_TIMEOUT) {
		delete $topicqueue->{lc $channel};
	}
	
	return (exists $topicqueue->{lc $channel}) ? 1 : undef;
}

sub queue_topic_delete {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $channel = shift;
	croak "No channel name given" unless defined $channel;
	
	my $topicqueue = $self->{'queue'}{'topic'};
	
	delete $topicqueue->{lc $channel};
	
	return 1;
}

sub queue_topic_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'queue'}{'topic'} = {};
	
	return 1;
}

# === Object methods ===

sub get_redirected_url {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $url = shift;
	croak "Invalid url" unless defined $url;
	
	my $lwp = $self->lwp;
	
	my $req = HTTP::Request->new(HEAD => $url);
	my $response = $lwp->simple_request($req);
	
	my $redir_url = $url;
	if ($response->is_redirect) {
		$redir_url = $response->header('Location');
	}
	
	return $redir_url;
}

sub search_google_web {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($q, $results, $safesearch) = @_;
	croak "Invalid search query" unless defined $q;
	$results //= 'large';
	$safesearch = $safesearch ? 'active' : 'off';
	
	my $key = $self->config_var('googlekey');
	
	my $res = eval {
		REST::Google::Search::Web->new(q => $q, key => $key, rsz => $results, safe => $safesearch);
	};
	if ($@) {
		$self->print_debug("Error calling Google search: $@");
		return undef;
	}
	if ($res->responseStatus != 200) {
		$self->print_debug("Error calling Google search: ".$res->responseDetails);
		return undef;
	}
	my @results = $res->responseData->results;
	return \@results;
}

sub search_google_web_count {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $q = shift;
	croak "Invalid search query" unless defined $q;
	my $results = 'large';
	my $safesearch = 'off';
	
	my $key = $self->config_var('googlekey');
	
	my $res = eval {
		REST::Google::Search::Web->new(q => $q, key => $key, rsz => $results, safe => $safesearch);
	};
	if ($@) {
		$self->print_debug("Error calling Google search: $@");
		return undef;
	}
	if ($res->responseStatus != 200) {
		$self->print_debug("Error calling Google search: $@");
		return undef;
	}
	
	return $res->responseData->cursor->estimatedResultCount;
}

sub search_google_images {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($q, $results, $safesearch) = shift;
	croak "Invalid search query" unless defined $q;
	$results //= 'large';
	$safesearch = $safesearch ? 'active' : 'off';
	
	my $key = $self->config_var('googlekey');
	
	my $res = eval {
		REST::Google::Search::Images->new(q => $q, key => $key, rsz => $results, safe => $safesearch);
	};
	if ($@) {
		$self->print_debug("Error calling Google search: $@");
		return undef;
	}
	if ($res->responseStatus != 200) {
		$self->print_debug("Error calling Google search: ".$res->responseDetails);
		return undef;
	}
	my @results = $res->responseData->results;
	return \@results;
}

sub search_youtube {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($q, $numresults, $safesearch) = @_;
	croak "Invalid search query" unless defined $q;
	$numresults = 25 unless defined $numresults;
	$safesearch = 'strict' unless defined $safesearch;
	$safesearch = $safesearch ? 'strict' : 'off';
	
	$q = uri_escape_utf8($q);
	$q =~ s/(\s|\%20)+/+/g;
	
	my $request = "http://gdata.youtube.com/feeds/api/videos?q=$q&max-results=$numresults&safeSearch=strict&v=2.0";
	
	my $result = get($request);
	return undef unless defined $result;
	my $videolist = XML::Atom::Feed->new(\$result);
	return undef unless defined $videolist and $videolist->entries;
	
	my @videoarray;
	foreach my $video ($videolist->entries) {
		push @videoarray, $video if $video->title;
	}
	
	return \@videoarray;
}

sub search_youtube_id {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $video_id = shift;
	croak "Invalid video ID" unless defined $video_id;
	
	my $request = "http://gdata.youtube.com/feeds/api/videos/$video_id";
	
	my $result = get($request);
	return undef unless defined $result;
	my $video = XML::Atom::Entry->new(\$result);
	return undef unless defined $video;
	
	return $video;
}

sub search_wikipedia_titles {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $q = shift;
	croak "Invalid search query" unless defined $q;
	
	my $searchTerm = uri_escape_utf8($q);
	
	my $request = "http://en.wikipedia.org/w/api.php?format=json&action=opensearch&search=$searchTerm";
	
	my $result = get($request);
	return undef unless defined $result and length $result;
	my $data = eval { decode_json($result); };
	warn $@ and return undef if $@;
	return undef unless defined $data;
	
	return $data->[1];
}

sub search_wikipedia_content {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $title = shift;
	croak "Invalid page title" unless defined $title;
	
	my $getTitle = uri_escape_utf8($title);
	
	my $numChars = 250;
	my $request = "http://en.wikipedia.org/w/api.php?format=json&action=query&redirects=1&prop=extracts|info&explaintext=1&exsectionformat=plain&exchars=$numChars&inprop=url&titles=$getTitle";
	
	my $result = get($request);
	return undef unless defined $result and length $result;
	my $data = eval { decode_json($result); };
	warn $@ and return undef if $@;
	
	my @pageids = keys %{$data->{'query'}{'pages'}};
	my $pageid = shift @pageids;
	
	return $data->{'query'}{'pages'}{$pageid};
}

sub search_wunderground_weather {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $query = shift;
	croak "No location given" unless defined $query;
	
	my $data = $self->cache_weather_results($query);
	
	unless (defined $data) {
		my $query_esc = uri_escape_utf8($query);
		
		my $apicode = $self->config_var('wundergroundkey');
		return undef unless defined $apicode;
		my $request = "http://api.wunderground.com/api/$apicode/conditions/forecast/geolookup/q/${query_esc}.json";
		
		my $result = get($request);
		return undef unless defined $result;
		
		$data = eval { decode_json($result); };
		warn $@ and return undef if $@;
		
		$self->cache_weather_results($query, $data);
	}
	
	return $data;
}

sub search_wunderground_weather_ip {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ip = shift;
	croak "No IP address given" unless defined $ip;
	
	my $data = $self->cache_weather_results("ip:$ip");
	
	unless (defined $data) {
		my $apicode = $self->config_var('wundergroundkey');
		return undef unless defined $apicode;
		my $request = "http://api.wunderground.com/api/$apicode/conditions/forecast/geolookup/q/autoip.json?geo_ip=$ip";
		
		my $result = get($request);
		return undef unless defined $result;
		
		$data = eval { decode_json($result); };
		warn $@ and return undef if $@;
		
		$self->cache_weather_results("ip:$ip", $data);
	}
	
	return $data;
}

sub search_wunderground_location {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $query = shift;
	croak "No query given" unless defined $query;
	
	$query = uri_escape_utf8($query);
	my $request = "http://autocomplete.wunderground.com/aq?h=0&query=$query";
	
	my $result = get($request);
	return undef unless defined $result;
	
	my $data = eval { decode_json($result); };
	warn $@ and return undef if $@;
	
	my $locs = $data->{'RESULTS'} // return undef;
	foreach my $loc (@$locs) {
		next unless $loc->{'type'} eq 'city';
		next unless defined $loc->{'lat'} and defined $loc->{'lon'};
		next unless $loc->{'lat'} >= -90 and $loc->{'lat'} <= 90
			and $loc->{'lon'} >= -180 and $loc->{'lon'} <= 180;
		if (defined $loc->{'l'} and $loc->{'l'} =~ m!/q/(.+)!) {
			return $1;
		}
	}
	return undef;
}

sub translate {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($phrase, $from, $to) = @_;
	croak "Invalid parameters for translate" unless defined $phrase and defined $from and defined $to;
	
	my $escaped_phrase = uri_escape_utf8($phrase);
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->ms_access_token;

	return undef unless defined $access_token;
	
	my $request = "http://api.microsofttranslator.com/v2/Http.svc/Translate?text=$escaped_phrase&from=$from&to=$to";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $xml = $self->xml;
		my $response_decoded = eval { $xml->load_xml('string' => $response->decoded_content); };
		warn $@ and return undef if $@;
		
		my $string = $response_decoded->documentElement;
		return undef unless defined $string;
		return $string->textContent;
	} else {
		$self->print_debug("Error requesting translation: ".$response->status_line);
		return undef;
	}
}

sub translate_detect {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $phrase = shift;
	croak "Invalid phrase to detect" unless defined $phrase;
	
	my $escaped_phrase = uri_escape_utf8($phrase);
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->ms_access_token;
	return undef unless defined $access_token;
	
	my $request = "http://api.microsofttranslator.com/V2/Http.svc/Detect?text=$escaped_phrase";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $xml = $self->xml;
		my $response_decoded = eval { $xml->load_xml('string' => $response->decoded_content); };
		warn $@ and return undef if $@;
		
		my $string = $response_decoded->documentElement;
		return undef unless defined $string;
		return $string->textContent;
	} else {
		$self->print_debug("Error requesting language detection: ".$response->status_line);
		return undef;
	}
}

sub translate_speak {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my ($phrase, $lang) = @_;
	croak "Invalid parameters" unless defined $phrase and defined $lang;
	
	my $escaped_phrase = uri_escape_utf8($phrase);
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->ms_access_token;
	return undef unless defined $access_token;
	
	my $request = "http://api.microsofttranslator.com/V2/Http.svc/Speak?text=$escaped_phrase&language=$lang&format=audio/mp3";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $audio = $response->content;
		my $dir = $self->config_var('htmldir') // '/tmp';
		make_path("$dir/speak");
		my $loc = $self->config_var('htmlloc') // 'http://www.google.com';
		my $filename = md5_hex($phrase) . '.mp3';
		open(my $fh, '>', "$dir/speak/$filename") or (warn "Error creating temp audio file: $!" and return undef);
		binmode $fh;
		print $fh $audio;
		close $fh or (warn "Error creating temp audio file: $!" and return undef);
		return "$loc/speak/$filename";
	} else {
		$self->print_debug("Error requesting language detection: ".$response->status_line);
		return undef;
	}
}

sub parse_tweet_text {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $text = shift;
	croak "Invalid tweet text" unless defined $text;
	
	decode_entities($text);
	$text =~ s/\n/ /g;
		
	my @urls = ($text =~ m!(https?://t.co/[[:graph:]]+)!g);
	foreach my $url (@urls) {
		my $url = $1;
		my $redir_url = $self->get_redirected_url($url);
		if ($redir_url ne $url) {
			$text =~ s/\Q$url/$redir_url/g;
		}
	}
	
	return $text;
}

sub search_twitter {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $term = shift;
	croak "Invalid parameters" unless defined $term;
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->twitter_access_token;
	return undef unless defined $access_token;
	
	my $q = uri_escape_utf8($term);
	my $count = 15;
	
	my $request = "https://api.twitter.com/1.1/search/tweets.json?q=$q&count=$count&include_entities=false";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $response_decoded = eval { decode_json($response->decoded_content); };
		warn $@ and return undef if $@;
		return $response_decoded->{'statuses'};
	} else {
		$self->print_debug("Error searching tweets: ".$response->status_line);
		return undef;
	}
}

sub search_twitter_id {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $id = shift;
	croak "Invalid parameters" unless defined $id;
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->twitter_access_token;
	return undef unless defined $access_token;
	
	my $request = "https://api.twitter.com/1.1/statuses/show.json?id=$id";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $response_decoded = eval { decode_json($response->decoded_content); };
		warn $@ and return undef if $@;
		return $response_decoded;
	} else {
		$self->print_debug("Error requesting info about tweet: ".$response->status_line);
		return undef;
	}
}

sub search_twitter_user {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	croak "Invalid parameters" unless defined $user;
	
	my $lwp = $self->lwp;
	
	my $access_token = $self->twitter_access_token;
	return undef unless defined $access_token;
	
	my $count = 10;
	
	my $request = "https://api.twitter.com/1.1/users/show.json?screen_name=$user&include_entities=false";
	
	my $response = $lwp->get($request, 'Authorization' => "Bearer $access_token");
	if ($response->is_success) {
		my $response_decoded = eval { decode_json($response->decoded_content); };
		warn $@ and return undef if $@;
		my %user_info = %$response_decoded;
		delete $user_info{'status'};
		$response_decoded->{'status'}{'user'} = \%user_info;
		return $response_decoded->{'status'};
	} else {
		$self->print_debug("Error retrieving user tweet: ".$response->status_line);
		return undef;
	}
}

sub lookup_geoip_record {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ip = shift;
	croak "Invalid parameters" unless defined $ip;
	
	my $geoip = $self->geoip;
	
	if (is_ipv4($ip) or is_ipv6($ip)) {
		my $geoip = $self->geoip;
		my $record = eval { $geoip->city_isp_org(ip => $ip); };
		warn $@ and return undef if $@;
		return $record;
	} else {
		return undef;
	}
}

sub lookup_geoip_location {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ip = shift;
	croak "Invalid parameters" unless defined $ip;
	
	my $record = $self->lookup_geoip_record($ip);
	return undef unless defined $record;
	
	my @subdivision_names;
	foreach my $subdivision ($record->subdivisions) {
		unshift @subdivision_names, $subdivision->name;
	}
	my @location_parts = ($record->city->name, @subdivision_names, $record->country->name);
	
	my $location = join ', ', grep { defined } @location_parts;
	
	my $isp = $record->traits->isp;
	my $org = $record->traits->organization;
	
	$location .= " [ $isp ]" if defined $isp;
	$location .= " [ $org ]" if defined $org;
	
	return $location;
}

sub lookup_geoip_weather {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $ip = shift;
	croak "Invalid parameters" unless defined $ip;
	
	my $record = $self->lookup_geoip_record($ip);
	return undef unless defined $record;
	
	my @location_parts = ($record->city->name);
	if ($record->country->iso_code eq 'US') {
		push @location_parts, $record->most_specific_subdivision->iso_code;
	} else {
		push @location_parts, $record->country->name;
	}
	my $location = join ', ', grep { defined } @location_parts;
	return $location;
}

sub search_wolframalpha {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $query = shift;
	croak "Invalid parameters" unless defined $query;
	my $ip = shift;
	
	my $appid = $self->config_var('wolframalphaid');
	
	$query = uri_escape_utf8($query);
	
	my $request = "http://api.wolframalpha.com/v2/query?input=$query&appid=$appid&format=plaintext";
	if (defined $ip) {
		$request .= "&ip=$ip";
	}
	
	my $response = get($request);
	return undef unless defined $response and $response =~ /^\</;
	
	my $xml = $self->xml;
	my $data = eval { $xml->load_xml('string' => $response); };
	warn $@ and return undef if $@;
	return undef unless defined $data;
	
	return $data;
}

sub pyx_random_black {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $pick = shift;
	
	my $dbh = $self->pyx_dbh;
	
	my $valid_sets = $self->config_var('pyx_card_sets');
	return undef unless defined $valid_sets;
	my @valid_sets = split ' ', $valid_sets;
	return undef unless @valid_sets;
	my $sets_str = join ',', map { '$'.$_ } (1..@valid_sets);
	my $pick_param = @valid_sets+1;
	
	my $pick_str = '';
	if (defined $pick and $pick > 0) {
		$pick_str = 'AND "bc"."pick"=$'.$pick_param.' ';
		push @valid_sets, $pick;
	}
	
	my $black_card = $dbh->selectrow_hashref('SELECT "bc"."text", "bc"."pick" FROM "black_cards" AS "bc" ' .
		'INNER JOIN "card_set_black_card" AS "csbc" ON "csbc"."black_card_id"="bc"."id" ' .
		'WHERE "csbc"."card_set_id" IN ('.$sets_str.') '.$pick_str.
		'ORDER BY random() LIMIT 1', undef, @valid_sets);
	return undef unless defined $black_card;
	
	$black_card->{'text'} = strip_pyx($black_card->{'text'});
	
	return $black_card;
}

sub pyx_random_white {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $count = shift // 1;
	
	$count = int abs $count;
	$count = 1 if $count < 1;
	$count = 10 if $count > 10;
	
	my $dbh = $self->pyx_dbh;
	
	my $valid_sets = $self->config_var('pyx_card_sets');
	return undef unless defined $valid_sets;
	my @valid_sets = split ' ', $valid_sets;
	return undef unless @valid_sets;
	my $sets_str = join ',', map { '$'.$_ } (1..@valid_sets);
	my $limit_param = @valid_sets+1;
	
	my $white_cards = $dbh->selectcol_arrayref('SELECT "wc"."text" FROM "white_cards" AS "wc" ' .
		'INNER JOIN "card_set_white_card" AS "cswc" ON "cswc"."white_card_id"="wc"."id" ' .
		'WHERE "cswc"."card_set_id" IN ('.$sets_str.') GROUP BY "wc"."id" ORDER BY random() LIMIT $'.$limit_param,
		undef, @valid_sets, $count);
	return [] unless defined $white_cards;
	
	$_ = strip_pyx($_) foreach @$white_cards;
	
	return $white_cards;
}

sub update_xkcd {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $num = shift;
	
	my $url;
	if (defined $num) {
		$url = "http://xkcd.com/$num/info.0.json";
	} else {
		$url = "http://xkcd.com/info.0.json";
	}
	
	my $lwp = $self->lwp;
	
	my $response = $lwp->get($url);
	if ($response->is_success) {
		my $xkcd = decode_json($response->decoded_content);
		$num = $xkcd->{'num'}//0;
		my $title = $xkcd->{'title'}//'';
		$self->cache_xkcd($num, $xkcd);
		$self->print_debug("Cached XKCD $num: $title");
	} else {
		$num //= 'default';
		warn "Failed to retrieve XKCD $num: ".$response->status_line unless $num eq '404';
		$self->cache_xkcd($num, { 'num' => $num });
		return undef;
	}
	
	return $num;
}

sub lastfm_recenttracks {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $user = shift;
	my $num = shift // 1;
	
	my $apikey = $self->config_var('lastfm_key');
	
	$user = uri_escape($user);
	
	my $request = "http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=$user&api_key=$apikey&format=json&limit=$num";
	my $response = get($request);
	return undef unless defined $response;
	
	my $response_decoded = eval { decode_json $response };
	warn $@ and return undef if $@;
	return undef unless defined $response_decoded;
	
	warn "LastFM error: ".$response_decoded->{'message'} and return undef if $response_decoded->{'error'};
	return $response_decoded->{'recenttracks'} // {};
}

sub mrr_rigdetails {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $rigid = shift;
	
	my $lwp = $self->lwp;
	
	my $request = "https://www.miningrigrentals.com/api/v1/rigs";
	my %post = ( 'method' => 'detail', 'id' => $rigid );
	
	my $response = $lwp->post($request, \%post);
	if ($response->is_success) {
		my $response_decoded = eval { decode_json($response->decoded_content); };
		warn $@ and return undef if $@;
		return $response_decoded;
	} else {
		$self->print_debug("Error requesting rig status: ".$response->status_line);
		return undef;
	}
}

sub mrr_riglist {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $list_type = shift;
	
	my $lwp = $self->lwp;
	
	my $request = "https://www.miningrigrentals.com/api/v1/rigs";
	my %post = ( 'method' => 'list', 'type' => $list_type, 'showoff' => 'no' );
	
	my $response = $lwp->post($request, \%post);
	if ($response->is_success) {
		my $response_decoded = eval { decode_json($response->decoded_content); };
		warn $@ and return undef if $@;
		return $response_decoded;
	} else {
		$self->print_debug("Error requesting rig list: ".$response->status_line);
		return undef;
	}
}

# === Internal use methods ===

sub load_config {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'config'} = DEFAULT_CONFIG;
	
	my $file = $self->{'config_file'};
	unless (defined $file and -r $file and -w $file) {
		$self->store_config;
		return 1;
	}
	
	open my $fh, '<', $file or die "Unable to open config file: $!";
	
	while (my $line = <$fh>) {
		chomp $line;
		my ($key, $value) = parse_config_line($line);
		next unless defined $key;
		$self->{'config'}{$key} = $value;
	}
	
	return 1;
}

sub store_config {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $file = $self->{'config_file'};
	die "Config file path not set" unless defined $file and length $file;
	
	my @conflines;
	tie @conflines, 'Tie::File', $file or die "Unable to open config file: $!";
	my %confindex;
	foreach my $i (0..$#conflines) {
		my ($key, $value) = parse_config_line($conflines[$i]);
		next unless defined $key;
		$confindex{$key} = { 'line' => $i, 'value' => $value };
	}
		
	foreach my $key (keys %{$self->{'config'}}) {
		my $newvalue = $self->{'config'}{$key};
		next unless defined $newvalue;
		my $curvalue;
		$curvalue = $confindex{$key}{'value'} if exists $confindex{$key};
		if (defined $curvalue) {
			if ($curvalue ne $newvalue) {
				my $i = $confindex{$key}{'line'};
				$conflines[$i] = "$key=$newvalue";
				$confindex{$key}{'value'} = $newvalue;
			}
		} else {
			my $i = scalar @conflines;
			$conflines[$i] = "$key=$newvalue";
			$confindex{$key} = { 'line' => $i, 'value' => $newvalue };
		}
	}
	
	untie @conflines;
	
	return 1;
}

sub store_config_var {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;
	croak "Invalid method parameters" unless defined $name;
	
	my $newvalue = $self->{'config'}{$name} // '';
	
	my $file = $self->{'config_file'};
	
	my @conflines;
	tie @conflines, 'Tie::File', $file or die "Unable to open config file: $!";
	my ($curline, $curvalue);
	foreach my $i (0..$#conflines) {
		my ($key, $value) = parse_config_line($conflines[$i]);
		next unless defined $key;
		if ($key eq $name) {
			$curline = $i;
			$curvalue = $value;
		}
	}
	
	unless ($curvalue eq $newvalue) {
		$conflines[$curline] = "$name=$newvalue";
	}
	
	untie @conflines;
	
	return 1;
}

sub load_db {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $file = $self->{'db_file'};
	unless (defined $file and -r $file and -w $file) {
		$self->store_db;
		return 1;
	}
	
	$self->{'db'} = retrieve $file;
	
	return (defined $self->{'db'}) ? 1 : undef;
}

sub store_db {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $file = $self->{'db_file'};
	die "Database file path not set" unless defined $file;
	
	my $stored = store $self->{'db'}, $file;
	
	return $stored;
}

sub load_quotes {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $file = $self->{'quote_file'};
	unless (defined $file and -r $file and -w $file) {
		$self->store_quotes;
		return 1;
	}
	
	open my $fh, '<', $file or die "Unable to open quote file: $!";
	binmode $fh, ':encoding(utf8)';
	
	my @quotes;
	while (my $line = <$fh>) {
		$line =~ s/\r?\n$//;
		push @quotes, $line;
	}
	
	close $fh;
	
	$self->{'quotes'} = \@quotes;
	
	return 1;
}

sub store_quotes {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $file = $self->{'quote_file'};
	die "Quote file path not set" unless defined $file;
	
	open my $fh, '>', $file or die "Unable to open quote file: $!";
	binmode $fh, ':encoding(utf8)';
	
	foreach my $quote (@{$self->{'quotes'}}) {
		$quote =~ s/\n/ /g;
		print $fh "$quote\n";
	}
	
	close $fh;
	
	return 1;
}

sub num_quotes {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	my $quotes = $self->{'quotes'};
	return scalar @$quotes;
}

sub quote {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $num = shift;
	croak "No quote number given" unless defined $num;
	
	my $quotes = $self->{'quotes'};
	return undef unless $num > 0 and exists $quotes->[$num-1];
	return $quotes->[$num-1];
}

sub add_quote {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $quote = shift // '';
	
	my $file = $self->{'quote_file'};
	die "Quote file path not set" unless defined $file;
	
	open my $fh, '>>', $file or die "Unable to open quote file: $!";
	binmode $fh, ':encoding(utf8)';
	
	$quote =~ s/\n/ /g;
	print $fh "$quote\n";
	
	close $fh;
	
	push @{$self->{'quotes'}}, $quote;
	
	$self->cache_quote_clear;
	$self->cache_quoten_clear;
	
	return 1;
}

sub del_quote {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $num = shift;
	croak "No line number given" unless defined $num;
	
	return undef if $num <= 0;
	
	my $file = $self->{'quote_file'};
	die "Quote file path not set" unless defined $file;
	
	my @quotes;
	tie @quotes, 'Tie::File', $file or die "Unable to open quote file: $!";
	
	return undef if $num > scalar @quotes;
	
	splice @quotes, $num-1, 1;
	
	untie @quotes;
	
	splice @{$self->{'quotes'}}, $num-1, 1;
	
	$self->cache_quote_clear;
	$self->cache_quoten_clear;
	
	return 1;
}

sub cache_quote_results {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $expr = shift;
	croak "No expression given" unless defined $expr;
	
	if (@_) {
		my $ids = shift;
		croak "Invalid quote results array" unless defined $ids and 'ARRAY' eq ref $ids;
		
		$self->{'cache'}{'quote'}{$expr}{'results'} = $ids;
	}
	
	return undef unless exists $self->{'cache'}{'quote'}{$expr};
	return $self->{'cache'}{'quote'}{$expr}{'results'};
}

sub cache_quote_last_id {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $expr = shift;
	croak "No expression given" unless defined $expr;
	
	if (@_) {
		my $last_id = shift;
		croak "Invalid last quote ID" unless defined $last_id and !ref $last_id;
		
		$self->{'cache'}{'quote'}{$expr} = {} unless defined $self->{'cache'}{'quote'}{$expr};
		$self->{'cache'}{'quote'}{$expr}{'last_id'} = $last_id;
	}
	
	return undef unless exists $self->{'cache'}{'quote'}{$expr};
	return $self->{'cache'}{'quote'}{$expr}{'last_id'};
}

sub cache_quote_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'cache'}{'quote'} = {};
	
	return 1;
}

sub cache_quoten_results {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $expr = shift;
	croak "No expression given" unless defined $expr;
	
	if (@_) {
		my $ids = shift;
		croak "Invalid quote results array" unless defined $ids and 'ARRAY' eq ref $ids;
		
		$self->{'cache'}{'quoten'}{$expr} = {} unless defined $self->{'cache'}{'quoten'}{$expr};
		$self->{'cache'}{'quoten'}{$expr}{'results'} = $ids;
	}
	
	return undef unless exists $self->{'cache'}{'quoten'}{$expr};
	return $self->{'cache'}{'quoten'}{$expr}{'results'};
}

sub cache_quoten_last_id {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $expr = shift;
	croak "No expression given" unless defined $expr;
	
	if (@_) {
		my $last_id = shift;
		croak "Invalid last quote ID" unless defined $last_id and !ref $last_id;
		
		$self->{'cache'}{'quoten'}{$expr}{'last_id'} = $last_id;
	}
	
	return undef unless exists $self->{'cache'}{'quoten'}{$expr};
	return $self->{'cache'}{'quoten'}{$expr}{'last_id'};
}

sub cache_quoten_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	
	$self->{'cache'}{'quoten'} = {};
	
	return 1;
}

sub cache_search_results {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift // '';
	
	if (@_) {
		my $results = shift;
		croak "Invalid search results array" unless defined $results and 'ARRAY' eq ref $results;
		
		$self->{'cache'}{'search'}{$name}{'results'} = $results;
		$self->{'cache'}{'search'}{$name}{'index'} = 0;
	}
	
	return $self->{'cache'}{'search'}{$name}{'results'};
}

sub cache_search_index {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift // '';
	
	if (@_) {
		my $index = shift;
		croak "Invalid search results index" unless defined $index and looks_like_number($index);
		
		$self->{'cache'}{'search'}{$name}{'index'} = $index;
	}
	
	return $self->{'cache'}{'search'}{$name}{'index'};
}

sub cache_search_next {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift // '';
	
	my $results = $self->{'cache'}{'search'}{$name}{'results'};
	my $index = $self->{'cache'}{'search'}{$name}{'index'};
	return undef unless defined $results and defined $index;
	return undef unless $index < @$results;
	
	++($self->{'cache'}{'search'}{$name}{'index'});
	
	return $results->[$index];
}

sub cache_search_clear {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $name = shift;

	if ($name) {	
		$self->{'cache'}{'search'}{$name} = {};
	} else {
		$self->{'cache'}{'search'} = {};
	}
	
	return 1;
}

sub cache_weather_results {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $code = shift;
	croak "No location code given" unless defined $code;
	
	if (@_) {
		my $results = shift;
		$self->{'cache'}{'weather'}{$code}{'location'} = $results->{'location'};
		$self->{'cache'}{'weather'}{$code}{'forecast'} = $results->{'forecast'};
		$self->{'cache'}{'weather'}{$code}{'current_observation'} = $results->{'current_observation'};
		$self->{'cache'}{'weather'}{$code}{'expiration'} = time+CACHE_WEATHER_EXPIRATION;
	}
	
	return undef unless exists $self->{'cache'}{'weather'}{$code};
	if ($self->{'cache'}{'weather'}{$code}{'expiration'} <= time) {
		delete $self->{'cache'}{'weather'}{$code};
		return undef;
	}
	return $self->{'cache'}{'weather'}{$code};
}

sub cache_xkcd {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $num = shift;
	
	my $xkcd_db = $self->db_var('xkcd');
	$self->db_var('xkcd', $xkcd_db = {'comics' => {}}) unless defined $xkcd_db;
	return $xkcd_db->{'comics'} unless defined $num;
	
	if (@_) {
		my $data = shift // return undef;
		$data->{'timestamp'} = time;
		
		$xkcd_db->{'comics'}{$num} = $data;
	}
	
	return $xkcd_db->{'comics'}{$num};
}

sub print_debug {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $msg = shift // '';
	
	return 1 unless $self->{'config'}{'debug'};
	
	my $localtime = scalar localtime;
	print "[ $localtime ] $msg\n";
	
	return 1;
}

sub print_echo {
	my $self = shift;
	croak "Not called as an object method" unless defined $self;
	my $msg = shift // '';
	
	return 1 unless $self->{'config'}{'echo'};
	
	my $localtime = scalar localtime;
	print "[ $localtime ] $msg\n";
	
	return 1;
}

sub autojoin {
	my $self = shift;
	my $irc = shift;
	foreach my $chan (@{$self->db_var('channels')}) {
		$irc->yield(join => $chan) if defined $chan;
	}
	return 1;
}

sub end_sessions {
	my $self = shift;
	POE::Kernel->alarm('check_xkcd');
	if (defined $self->{'irc'}) {
		$self->irc->yield(join => '0');
		$self->resolver->shutdown;
		$self->irc->yield(shutdown => 'Bye');
		undef $self->{'irc'};
	}
	$self->print_debug("Disconnected. Saving data.");
	$self->store_db;
	$self->store_config;
	$self->store_quotes;
	kill 9, keys %{$self->{'child_pids'}};
	$self->{'child_pids'} = {};
}

# === Module functions ===

sub parse_config_line {
	my $line = shift;
	croak "Invalid function parameters" unless defined $line;
	
	return undef if $line =~ /^\s*[;#]/;
	if ($line =~ /^\s*([^=]+?)\s*=\s*(.*?)\s*$/) {
		return ($1, $2);
	}
	return undef;
}

sub strip_google {
	my $arg = shift;
	my $b_code = chr(2);
	$arg =~ s/<b>/$b_code/g;
	$arg =~ s/<\/b>/$b_code/g;
	return decode_entities $arg;
}

sub strip_xml { return strip_wide(@_, 128); }
sub strip_wide {
	my $arg = shift;
	my $len = shift;
	$len = 256 unless defined $len and $len > 0;
	my @chars = split '', $arg;
	foreach (0..$#chars) {
		my $charnum = ord $chars[$_];
		if ($charnum > $len-1) {
			my $highnum = int($charnum/$len);
			my $highchar = chr $highnum;
			my $lowchar = chr $charnum-$highnum*$len;
			$chars[$_] = strip_wide("$highchar$lowchar", $len);
		}
	}
	return join('', @chars);
}

sub strip_pyx {
	my $text = shift // return undef;
	
	$text = decode_entities($text);
	
	my $b_code = chr(2);
	$text =~ s!<span.*?</span>!!g;
	$text =~ s!</?i>!/!g;
	$text =~ s!</?b>!$b_code!g;
	$text =~ s!</?u>!_!g;
	$text =~ s!<br/?>! !g;
	$text =~ s!<.*?>!!g;
	$text =~ s!\r?\n!!g;
	
	return $text;
}

1;

