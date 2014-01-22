// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.support;

/// Miscellaneous support functions for Disasterclass.

import std.typecons;
import std.traits;
import std.bitmanip : bigEndianToNative;
import std.string : format;
import std.conv;
debug import std.stdio : stderr;


/// Helpful alises for sized integers used in Minecraft data.
alias ushort BlockID;
alias ushort ItemID;      /// ditto
alias ubyte BiomeType;    /// ditto
alias ubyte BlockData;    /// ditto
alias ushort ItemDamage;  /// ditto

/// Type to hold a block id and its associated data value.
alias Tuple!(BlockID, "id", BlockData, "data") BlockIDAndData;
enum BlockIDAndData NoBlock = BlockIDAndData(BlockID.max, BlockData.max);

/// General Minecraft constants.
enum uint NBlockTypes = 4096;
enum BiomeType UnknownBiome = -1; /// ditto


T alignTo(T)(T n, size_t boundary)
if (isIntegral!T && T.min == 0u)
in {
	assert( (boundary & (boundary - 1)) == 0, "alignTo boundary must be a power of 2 (not %d)".format(boundary));
}
body
{
	return (n + (boundary - 1)) & ~(boundary - 1);
}
unittest {
	void check(T)(T n, T boundary, T expected) {
		T result = alignTo!(T)(n, boundary);
		assert(result == expected, "alignTo!(%s)(%d) returned %d, not %d".format(T.stringof, n, result, expected));
	}

	check!size_t(3u, 16u, 16u);
}

/// Convenience function that implements $(D_KEYWORD bigEndianToNative) on dynamic arrays.
package T bigEndianDynamicToNative(T)(in ubyte[] ar)
in {
	assert(ar.length == T.sizeof);
}
body
{
	ubyte[T.sizeof] ars = ar;
	return bigEndianToNative!T(ars);
}
unittest
{
	immutable ubyte[8] source = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef];
	assert(bigEndianDynamicToNative!ushort(source[0..2]) == 0x0123U);
	assert(bigEndianDynamicToNative!uint(source[0..4]) == 0x01234567U);
	assert(bigEndianDynamicToNative!ulong(source[0..8]) == 0x0123456789abcdefUL);
}

/// Pack a ubyte[] as nibbles. The earlier bytes go in the lower nibbles.
void packNibbles(in ubyte[] src, ubyte[] dst)
in {
	assert(src.length == dst.length * 2, "Can't pack src of length %d to dst of length %d".format(src.length, dst.length));
}
body
{
	foreach (i ; 0..dst.length) {
		dst[i] = cast(ubyte) ((src[i*2] & 0xf) | (src[i*2+1] << 4));
	}
}

void unpackNibbles(in ubyte[] src, ubyte[] dst)
in {
	assert(src.length * 2 == dst.length, "Can't unpack src of length %d to dst of length %d".format(src.length, dst.length));
}
body
{
	foreach (i ; 0..src.length) {
		dst[i*2]     = src[i] & 0xf;
		dst[i*2 + 1] = src[i] >> 4;
	}
}

unittest
{
	immutable ubyte[] unpackedOriginal = cast(immutable(ubyte[])) x"01 03 05 07 09 0a 0c 0e";
	ubyte[] unpacked = unpackedOriginal.dup, packed = new ubyte[4];
	packNibbles(unpacked, packed);
	assert(packed == cast(ubyte[]) x"3175a9ec", "packed == %s".format(packed));
	unpackNibbles(packed, unpacked);
	assert(unpacked == cast(const(ubyte)[]) x"01 03 05 07 09 0a 0c 0e");
}

//R choose(R, C, Args...)(Args args)
//if (_chooseArgsSatisfied!(R, C, Args))
//{

//}

//template _chooseArgsSatisfied(R, C, Args...)
//{
//	static if (Args.length == 0) {
//		enum bool _chooseArgsSatisfied = true;
//	}
//	else static if (Args.length == 1) {
//		enum bool _chooseArgsSatisfied = false;
//	}
//	else {
//		enum bool _chooseArgsSatisfied =
//		is(Args[0] == R) &&
//		is(Args[1] == C) &&
//		_chooseArgsSatisfied(R, C, Args[2..$]);
//	}
//}

/++
	Formats a capacity into a human-readable string, to 2 decimal places.
	Params:
		cap = The capacity (in bytes) to format.
		useSI = Whether to use SI (units are multiples of 1024 apart) or decimal (units are multiples of 1000 apart).
+/
string asCapacity(ulong cap, bool useSI = false)
{
	if (useSI) goto LUseSI;

	if (cap >= 1_000_000_000_000_000_000UL) {
		return "%.2f EB".format(cap / 1.0e18);
	}
	if (cap >= 1_000_000_000_000_000UL) {
		return "%.2f PB".format(cap / 1.0e15);
	}
	if (cap >= 1_000_000_000_000UL) {
		return "%.2f TB".format(cap / 1.0e12);
	}
	if (cap >= 1_000_000_000UL) {
		return "%.2f GB".format(cap / 1.0e9);
	}
	if (cap >= 1_000_000UL) {
		return "%.2f MB".format(cap / 1.0e6);
	}
	if (cap >= 1_000UL) {
		return "%.2f KB".format(cap / 1.0e3);
	}
	goto Lbytes;

	LUseSI:
	if (cap >= (1UL<<60)) {
		return format("%.2f EiB", (cap >> 50) / 1024.0);
	}
	if (cap >= (1UL<<50)) {
		return format("%.2f PiB", (cap >> 40) / 1024.0);
	}
	if (cap >= (1UL<<40)) {
		return format("%.2f TiB", (cap >> 30) / 1024.0);
	}
	if (cap >= (1UL<<30)) {
		return format("%.2f GiB", (cap >> 20) / 1024.0);
	}
	if (cap >= (1UL<<20)) {
		return format("%.2f MiB", (cap >> 10) / 1024.0);
	}
	if (cap >= (1UL<<10)) {
		return format("%.2f KiB", cap / 1024.0);
	}

	Lbytes:
	return to!string(cap) ~ " B";
} 


