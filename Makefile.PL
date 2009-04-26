# $Id: Makefile.PL,v 3.9 2005/04/14 19:23:16 chris Exp $

use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

WriteMakefile(
			  'NAME'	=> 'POE::Component::Win32::Service',
			  'PREREQ_PM' => {
							  'POE'    => 0.31,
							  'Win32::Service' => 0,
							  'Carp'   => 0,
							 },
			  'VERSION_FROM' => 'lib/POE/Component/Win32/Service.pm', # finds $VERSION
			  'dist' => { 'COMPRESS' => 'gzip --best' },
			 );
