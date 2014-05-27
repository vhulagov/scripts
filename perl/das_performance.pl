#!/usr/bin/env perl

#use strict;
use warnings;

use JSON;
use CGI qw/:standard/;
use CGI::Carp qw(warningsToBrowser fatalsToBrowser);
use Data::Dumper;
use DBI;

use utf8;
use open ':encoding(UTF-8)';

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $table="das_performance";

my $q=CGI->new;
#print $q->header;
my %params = map { $_ => ($q->param($_))[0] } $q->param;

use vars '$dbh','$sth';
	$dbh = 'DBI'->connect('DBI:mysql:database=validation_results;host=localhost;port=3306','root')||die $DBI::errstr;

if (%params) {
	local $" = ', ';
	$dbh->do("REPLACE INTO $table (@{[keys %params]}) VALUES (@{[('?') x keys %params]})", undef, values %params)||die $DBI::errstr;
	my $result = $dbh->{mysql_insertid};
} else {
#	print "test_id block_size buffered direct IO_engine IO_depth duration IOPS_disk_rand_read IOPS_disk_rand_write IOPS_disk_seq_read IOPS_disk_seq_write latency_disk_rand_read latency_disk_rand_write latency_disk_seq_read latency_disk_seq_write bandwidth_disk_rand_read bandwidth_disk_rand_write bandwidth_disk_seq_read bandwidth_disk_seq_write<br />";
	$sth = $dbh->prepare("SELECT * from $table") || die $dbh->errstr;
	$sth->execute() || die $sth->errstr;
	my $records = $sth->fetchall_arrayref({}) or die "$dbh -> errstr\n";

	#print join(" ", @{$sth->{NAME}}) . "\n";
#	while (my $r = $sth->fetchrow_arrayref) {
#		print join(" ", @$r) . "<br />";
#	}

	my %json;
	my $results = [map {"item" => $_}, @$records];
	#delete $key->{'item'} for keys %$hash;
	#push(@$results, %$item);

	$json{'hits'} = scalar(keys $results);
	$json{'request'} = { start => 0, limit => 50 };
	$json{'results'} =  $results ;

	# Convert %json to a scalar containing a JSON formatted string
	my $json = to_json(\%json, {pretty=>'1'});

	    print 'Access-Control-Allow-Origin: *';
	    print 'Access-Control-Allow-Methods: GET';
	    print "Content-type: application/javascript\n\n";
	    print _jqjsp . '(' . $json . ');';
}
