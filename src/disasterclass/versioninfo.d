// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.versioninfo;

import std.string : format;

struct Version
{
	enum uint
	 Major     = 0
	,Minor     = 0
	,Revision  = 35
	;
	
	enum string String = "%d.%d.%d".format(Major, Minor, Revision);

	debug enum string _debug = " (DEBUG)";
	else  enum string _debug = "";

	version(D_LP64) enum string _arch = "64-bit";
	else            enum string _arch = "32-bit";

	version(OSX)          enum string _platform = "Mac OS X";
	else version(Windows) enum string _platform = "Windows";
	else version(Linux)   enum string _platform = "Linux";
	else static assert(0, "Unsupported platform");

	enum string Platform = _platform ~ _debug ~ ' ' ~ _arch;

}

version(dc13PrintVersion) void main()
{
	import std.stdio;

	writeln(Version.String);
}
