#!/usr/bin/env perl

use 5.020;
use strict;
use warnings;
use Attean;
use URI;
use Attean::RDF qw(iri blank literal quad);
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Status;
use Test::More;
use Data::Dumper;
use Encode qw(encode encode_utf8);
use Test::Attean::W3CManifestTestSuite;

my $rdf_type		= iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#type');
my $Manifest		= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#Manifest');
my $mf_name			= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#name');
my $entries			= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#entries');
my $requests		= iri('http://www.w3.org/2011/http#requests');
my $authority		= iri('http://www.w3.org/2011/http#connectionAuthority');
my $mf_action		= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#action');
my $absolutePath	= iri('http://www.w3.org/2011/http#absolutePath');
my $methodName		= iri('http://www.w3.org/2011/http#methodName');
my $ht_body			= iri('http://www.w3.org/2011/http#body');
my $ht_headers		= iri('http://www.w3.org/2011/http#headers');
my $cnt_encoding	= iri('http://www.w3.org/2011/content#characterEncoding');
my $cnt_chars		= iri('http://www.w3.org/2011/content#chars');
my $ht_fieldName	= iri('http://www.w3.org/2011/http#fieldName');
my $ht_fieldValue	= iri('http://www.w3.org/2011/http#fieldValue');
my $ht_resp			= iri('http://www.w3.org/2011/http#resp');
my $expectedBoolean	= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#expectedBoolean');
my $expectedFormat	= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#expectedFormat');
my $expectedStatus	= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#expectedStatus');
my $expectedLocation= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#expectedLocation');
my $mf_expectation	= iri('http://www.w3.org/2001/sw/DataAccess/tests/test-manifest#expectation');
my $ut_graphData	= iri('http://www.w3.org/2009/sparql/tests/test-update#graphData');
my $ut_graph		= iri('http://www.w3.org/2009/sparql/tests/test-update#graph');
my $rdfs_label		= iri('http://www.w3.org/2000/01/rdf-schema#label');

if (scalar(@ARGV) < 2) {
	print <<"END";

Usage: $0 http://endpoint/sparql http://endpoint/gsp [test-pattern] [-v]

Run the SPARQL Protocol tests against the specified endpoint.
If [test-pattern] is given, only runs tests whose IRI match the given regex pattern.

END

	exit(1);
}

my $prot_endpoint	= shift;
my $endpoint		= shift;
my $pattern		= shift // '';
my $flags		= shift // '';
my $verbose		= ($flags =~ /-v/);
my $list		= ($flags =~ /-l/);
my $euri		= URI->new($endpoint);
$euri->fragment(undef);
$euri->query(undef);
$endpoint		= $euri->as_string;

warn "GSP Endpoint    : $endpoint\n" if ($verbose);
warn "SPARQL Endpoint : $prot_endpoint\n" if ($verbose);

my $manifest	= shift // 'manifest.ttl';
my $graph		= iri('http://graph-name/');
my $store = Attean->get_store('Memory')->new();
my $parser = Attean->get_parser('Turtle')->new();
{
	open(my $fh, '<:utf8', $manifest) or die $!;
	my $iter = $parser->parse_iter_from_io($fh);
	my $quads = $iter->as_quads($graph);
	$store->add_iter($quads);
}

my $ua		= LWP::UserAgent->new();

# clear dataset
my $resp	= $ua->post($prot_endpoint, {update => 'DROP ALL'});
unless ($resp->is_success) {
	warn 'POST failed to endpoint: ' . Dumper($endpoint);
	warn $resp->as_string;
	die $resp->status_line;
}

my $model	= Attean::QuadModel->new( store => $store );
my ($m)		= $model->subjects($rdf_type, $Manifest)->elements;
my ($obj)	= $model->objects($m, $entries)->elements;
my @tests	= $model->get_list($graph, $obj)->elements;
foreach my $test (@tests) {
	if ($pattern) {
		next unless ($test->value =~ /$pattern/);
	}
	my ($name)		= $model->objects($test, $mf_name)->elements;
	if ($list) {
		say sprintf("%-75s\t%s", $name->value, $test->value);
		next;
	}
	subtest $test->value => sub {
		my $testname	= $name->value;
		say "============================================= $testname =============================================" if ($verbose);
		diag("Test name: " . $name->value);
		run_test($ua, $prot_endpoint, $endpoint, $model, $test);
	};
}
exit if ($list);
done_testing();

sub make_request {
	my $endpoint	= shift;
	my $model		= shift;
	my $req			= shift;
	my $auth_v		= shift;
	my $real_auth	= shift;
	my $templates	= shift;
	my ($path)		= $model->objects($req, $absolutePath)->elements;
	use Data::Dumper;
	my $path_v		= $path->value;
	foreach my $t (keys %$templates) {
		my $v	= $templates->{$t};
		my $i	= index($path_v, $t);
		if ($i >= 0) {
			substr($path_v, $i, length($t), $v);
		}
	}
	
	my $pathuri		= new URI($path_v);
	my ($method)	= $model->objects($req, $methodName)->elements;
	my ($body)		= $model->objects($req, $ht_body)->elements;
	my ($headers)	= $model->objects($req, $ht_headers)->elements;

	my $m			= HTTP::Request->new();
	$m->method($method->value);
	my $uri	= new URI($endpoint);

	my $test_path	= $pathuri->path;
	$test_path		=~ s#/gsp#$uri->path#e;
	$uri->path($test_path);
	$uri->query($pathuri->query);
	
	my $uri_v	= $uri->as_string;
	# fixup
	$uri_v	=~ s/$auth_v/$real_auth/e;

	
	$m->uri(URI->new($uri_v));
	
	if ($body) {
		my ($content)		= $model->objects($body, $cnt_chars)->elements;
		my ($encoding)		= $model->objects($body, $cnt_encoding)->elements;

		# fixup
		$content	=~ s/$auth_v/$real_auth/ge;

		my $bytes			= encode($encoding->value, $content->value);
		$m->content($bytes);
	}
	
	my @headers	= $model->get_list($graph, $headers)->elements;
	foreach my $h (@headers) {
		my ($key)		= $model->objects($h, $ht_fieldName)->elements;
		my ($value)		= $model->objects($h, $ht_fieldValue)->elements;
		$m->header($key->value => $value->value);
	}

	return $m;
}

sub validate_response {
	my $endpoint	= shift;
	my $model	= shift;
	my $test	= shift;
	my $name	= $test->value;
	my $req		= shift;
	my $m		= shift;
	my $auth_v		= shift;
	my $real_auth	= shift;
	my $templates	= shift;
	
	warn "Validating response..." if ($verbose);
	
	my ($resp)	= $model->objects($req, $ht_resp)->elements;
	unless ($resp) {
		return fail('No expected response data for test');
	}

	my (@expected_location)	= $model->objects($resp, $expectedLocation)->elements;
	foreach my $loc (@expected_location) {
		my $header			= $m->header('Location');
		ok($header, 'Location header value');
		my $var				= $loc->value;
		$templates->{ $var }	= $header;
	}

	my (@expected_status)	= $model->objects($resp, $expectedStatus)->elements;
	if (scalar(@expected_status)) {
		my %ok				= map { $_ => 1 } map { $_->value } @expected_status;
		my $code			= $m->code;
		my $digit			= int($code / 100);
		my $actual_class_iri		= "http://www.w3.org/2011/http-statusCodes#StatusCode${digit}xx";
		my $message					= status_message($code);
		$message					=~ s/ //g;
		my $actual_iri				= "http://www.w3.org/2011/http-statusCodes#$message";
		
# 		warn "Actual class IRI: $actual_class_iri\n";
# 		warn "Actual IRI: $actual_iri\n";
		
		if (exists $ok{$actual_class_iri}) {
			pass("status code matches class ${digit}xx")
		} elsif (exists $ok{$actual_iri}) {
			pass("status code matches ($code)")
		} else {
			fail("got status code: " . $m->status_line . ' but expecting one of: ' . join(',', keys %ok))
		}
	}
	my ($expected_format)	= $model->objects($resp, $expectedFormat)->elements;
	if ($expected_format) {
		my $ct	= $m->header('Content-Type');
		my $expected	= $expected_format->value;
		if ($expected eq 'tabular') {
			like($ct, qr#^application/sparql-results[+](json|xml)|text/csv|text/tab-separated-values#, "expected tabular result but got $ct");
		} elsif ($expected eq 'boolean') {
			like($ct, qr#^application/sparql-results[+](json|xml)|text/plain#, "expected boolean result but got $ct");
		} elsif ($expected eq 'RDF') {
			like($ct, qr#^(application/rdf-xml)|text/((n-(triples|quads))|turtle)|application/ld[+]json#, "expected RDF result but got $ct")
		} else {
			die("Unexpected format value '$expected'");
		}
	}
	my ($expected_bool)		= $model->objects($resp, $expectedBoolean)->elements;
	if ($expected_bool) {
		my $ct	= $m->header('Content-Type');
		my $body	= $m->decoded_content;
		my $expected	= $expected_bool->value;
		if ($ct eq 'application/sparql-results+json') {
			like($body, qr#"boolean"\s*:\s*${expected}#sm, "expected boolean $expected");
		} elsif ($ct eq 'application/sparql-results+xml') {
			like($body, qr#<boolean>${expected}</boolean>#sm, "expected boolean $expected");
		} elsif ($ct eq 'text/plain') {
			like($body, qr#${expected}#sm, "expected boolean $expected");
		} else {
			die("validate expected boolean: " . $expected_bool->value);
		}
	}

	my ($expected_headers)	= $model->objects($resp, $ht_headers)->elements;
	if ($expected_headers) {
		my @headers	= $model->get_list($graph, $expected_headers)->elements;
		foreach my $h (@headers) {
			my ($key)				= $model->objects($h, $ht_fieldName)->elements;
			my ($expected_value_l)	= $model->objects($h, $ht_fieldValue)->elements;
			my $expected_value		= $expected_value_l->value;
			my $actual_value		= $m->header($key->value);
			if ($expected_value =~ m<$actual_value; charset=utf-8>i) {
				pass('content-type with ignored charset=utf-8');
			} else {
				$actual_value	=~ s/ //g;
				$expected_value	=~ s/ //g;
				is($actual_value, $expected_value, "expected header: " . $key->value);
			}
		}
	}

	my ($expected_body)	= $model->objects($resp, $ht_body)->elements;
	if ($expected_body) {
		my $ct		= $m->header('Content-Type');
		if (not defined($ct)) {
			fail('No content-type in response');
			return;
		}
		$ct			=~ s/;.*//;
		
# 		warn "Body content-type: $ct\n";
		my $pclass		= Attean->get_parser( media_type => $ct );
		unless ($pclass) {
			fail("Unrecognized media type for response: $ct");
			return;
		}
		my $parser		= $pclass->new();
		my ($chars)		= $model->objects($expected_body, $cnt_chars)->elements;
		my $actual		= $m->decoded_content;
		my $expected	= $chars->value;
		
		# fixup
		$actual		=~ s/$auth_v/$real_auth/ge;
		$expected	=~ s/$auth_v/$real_auth/ge;

		warn "Actual response body: " . Dumper($actual) if ($verbose);
		warn "Expected response body: " . Dumper($expected) if ($verbose);
		
		my $actual_iter		= $parser->parse_iter_from_bytes(encode_utf8($actual));
		my $expected_iter	= $parser->parse_iter_from_bytes(encode_utf8($expected));
		my $eqtest	= Attean::BindingEqualityTest->new();
		my $ok		= eval { ok( $eqtest->equals( $actual_iter, $expected_iter ), 'expected triples' ) or diag($eqtest->error) };
		unless ($ok) {
			warn Dumper({expected => $expected, actual => $actual});
		}
		if ($@) {
			diag($@);
		}
# 		fail('TODO: body');
	}

	my ($expectation)		= $model->objects($resp, $mf_expectation)->elements;
	if ($expectation) {
		fail("validate expectation: " . $expectation->value);
	}
}

sub setup_dataset {
	my $ua			= shift;
	my $endpoint	= shift;
	my $model		= shift;
	my $test		= shift;
	warn "Clearing dataset ...\n" if ($verbose);
	say "REQUEST: POST $endpoint update=DROP ALL" if ($verbose);
	my $resp	= $ua->post($endpoint, {update => 'DROP ALL'});
	say "RESPONSE:\n" . $resp->as_string if ($verbose);
	die $resp->status_line unless ($resp->is_success);
}

sub run_test {
	my $ua			= shift;
	my $prot_endpoint	= shift;
	my $endpoint	= shift;
	my $model		= shift;
	my $test		= shift;
	say '# ' . $test->value if ($verbose);
	my ($action)	= $model->objects($test, $mf_action)->elements;
	unless ($action) {
		return fail('no action data for test');
	}
	my ($reqs)		= $model->objects($action, $requests)->elements;
	my @reqs		= $model->get_list($graph, $reqs)->elements;
	my ($auth)		= $model->objects($action, $authority)->elements;
	my $auth_v		= $auth->value;
	my $uri			= new URI($endpoint);
	my $real_auth	= $uri->authority;
	
	$ua->get("$prot_endpoint?================================================================NEWTEST");
	setup_dataset($ua, $prot_endpoint, $model, $test);
	
	say scalar(@reqs) . ' request(s) in test' if ($verbose);
	my $req_number	= 1;
	my $templates	= {};
	foreach my $req (@reqs) {
		my $name	= "Request " . $req_number++;
		subtest $name => sub {
			say "--------------------------------- $name ---------------------------------" if ($verbose);
			my $m	= make_request($endpoint, $model, $req, $auth_v, $real_auth, $templates);
			say "Request [[" . $m->method . " " . $m->uri . "]]\n" if ($verbose);
	# 		next unless ($m->method eq 'GET');
			say "REQUEST:\n" . $m->as_string if ($verbose);
			my $resp	= $ua->request($m);
			say "RESPONSE:\n" . $resp->as_string if ($verbose);
			diag(sprintf('%s %s', $m->method, $m->uri));
			validate_response($endpoint, $model, $test, $req, $resp, $auth_v, $real_auth, $templates);
		};
		last;
	}
}