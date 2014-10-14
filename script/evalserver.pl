#!/usr/bin/env perl

use strict;
use warnings;
use Proc::PID::File::Fcntl;
use App::EvalServer;
use POE;
use Getopt::Long;

use constant PIDFILE => '/var/run/evalserver.pid';
use constant LISTEN_PORT => 60234;

my ($restart, $stop, $daemon);

GetOptions('restart' => \$restart, 'stop' => \$stop, 'daemon!' => \$daemon);

my $cur_pid = Proc::PID::File::Fcntl->getlocker('path' => PIDFILE);

if ($restart or $stop) {
	if ($cur_pid) {
		my $signalled = kill 'INT', $cur_pid;
		die "Error stopping eval server\n" unless $signalled;
		
		my $running = 1;
		for my $i (0..30) {
			sleep 1;
			$running = Proc::PID::File::Fcntl->getlocker('path' => PIDFILE);
			last unless $running;
		}
		die "Eval server not stopped\n" if $running;
	}
} else {
	die "Eval server is already running with process ID $cur_pid\n" if $cur_pid;
}

if ($stop) {
	exit;
}

my $pidlock = eval { Proc::PID::File::Fcntl->new('path' => PIDFILE); };
die "Error starting eval server: $@\n" if $@;

my $server = App::EvalServer->new(
	port => LISTEN_PORT,
	daemonize => ($daemon ? 1 : 0),
);

$server->run;
POE::Kernel->run;
