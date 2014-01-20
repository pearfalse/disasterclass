// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.vectors;

/// Contains all vector and range types specially defined in Minecraft semantics.

import disasterclass.support;

import std.typecons : Tuple;
import std.math : floor, ceil;
import std.algorithm : min, max, abs;

import std.stdio;

/++
	Structure to encapsulate a 2-dimensional co-ordinate. Its two variables are named $(D_KEYWORD x) and $(D_KEYWORD z) to match Minecraft's co-ordinate system.
+/
struct CoordXZ
{
	int x, z;

	@property CoordXZ regionSubCoord()
	{
		return this & 31;
	}

	hash_t toHash() const
	{
		return (x << 5) + z; // TODO: can we improve on this?
	}

	bool opEquals(CoordXZ that) const
	{
		//debug stderr.writefln("opEquals %s vs %s", this, that);
		return this.x == that.x && this.z == that.z;
	}

	/++
		$(D_KEYWORD CoordXZ)s are compared first by Z co-ordinate, then by X co-ordinate.
	+/
	int opCmp(CoordXZ that) const
	{
		//debug stderr.writefln("opCmp %s vs %s", this, that);
		int rz = this.z - that.z;
		if (rz) return rz;
		else return (this.x - that.x);
	}

	string toString() const
	{
		return format("(%d,%d)", x, z);
	}

	/++
		Unary positation.
	+/
	CoordXZ opUnary(string op : "+")() const
	{
		return this;
	}

	/++
		Unary negation.
	+/
	CoordXZ opUnary(string op : "-")() const
	{
		return CoordXZ(-x, -z);
	}

	/++
		Applies an operation to two $(D_KEYWORD CoordXZ)s. Note that the variables are transformed separately (i.e. $(D_KEYWORD opBinary!"*"()) does not return a cross product).

		Examples:
		---
		auto result = CoordXZ(3,3) * CoordXZ(4,5); // result == CoordXZ(12, 15)
		---
	+/
	CoordXZ opBinary(string op)(CoordXZ that) const
	{
		return CoordXZ(mixin("this.x "~op~" that.x"), mixin("this.z "~op~" that.z"));
	}

	ref CoordXZ opOpAssign(string op)(CoordXZ that) /// ditto
	{
		mixin("this.x "~op~"= that.x;");
		mixin("this.z "~op~"= that.z;");
		return this;
	}

	/++
		Applies a scalar operation to a $(D_KEYWORD CoordXZ) by applying the operation with the scalar to each $(D_KEYWORD CoordXZ) separately.

		Examples:
		---
		auto result = CoordXZ(4,5) + 9000; // result == CoordXZ(9004, 9005)
		---
	+/
	CoordXZ opBinary(string op)(int that) const
	{
		return CoordXZ(mixin("this.x "~op~" that"), mixin("this.z "~op~" that"));
	}

	ref CoordXZ opOpAssign(string op)(int that) /// ditto
	{
		mixin("this.x "~op~"= that;");
		mixin("this.z "~op~"= that;");
		return this;
	}

	/// Returns true iff $(D_PARAM that) is adjacent to $(D_PARAM this). A shared corner counts as adjacent (i.e. there are up to 8 bordering co-ordinates).
	bool borders(CoordXZ that) const
	{
		return max(abs(this.x - that.x), abs(this.z - that.z)) <= 1;
	}

	unittest
	{
		CoordXZ xz = CoordXZ(323, 4);
		assert(xz == CoordXZ(323, 4));
		assert(xz % 32 == CoordXZ(3, 4));
		assert((CoordXZ(1, 2) & 31) == CoordXZ(1, 2));
		assert((CoordXZ(-1, -1) & 31) == CoordXZ(31, 31));
		assert(CoordXZ(-33, -70) >> 5 == CoordXZ(-2, -3));

		assert(CoordXZ(4, 4) > CoordXZ(3, 3));
		assert(CoordXZ(2, 3) < CoordXZ(3, 3));

		assert(CoordXZ(10, 10).borders(CoordXZ(11, 10)));
		assert(CoordXZ(10, 10).borders(CoordXZ(10, 11)));
		assert(CoordXZ(10, 10).borders(CoordXZ(9, 9)));
	}
}

/// Encapsulates a 3-dimensional co-ordinate.
struct CoordXYZ
{
	int x, y, z;

	hash_t toHash() const
	{
		return (y << 10) + (x << 5) + z; // TODO: test
	}

	bool opEquals(CoordXYZ that) const
	{
		return this.x == that.x && this.y == that.y && this.z == that.z;
	}

	int opCmp(CoordXYZ that) const
	{
		int ry = this.y - that.y;
		if (ry) return ry;
		int rz = this.z - that.z;
		if (rz) return rz;
		return (this.x - that.x);
	}

	/++
		Unary positation.
	+/
	CoordXYZ opUnary(string op : "+")() const
	{
		return this;
	}

	/++
		Unary negation.
	+/
	CoordXYZ opUnary(string op : "-")() const
	{
		return CoordXYZ(-x, -y, -z);
	}

	/++
		Binary operation. Note that each dimension is processed on its own (e.g. multiplying two $(D_PARAM CoordXYZ)s together) does not produce a cross product).
	+/
	CoordXYZ opBinary(string op)(int that) const
	{
		return CoordXYZ(
			mixin("x "~op~" that"),
			mixin("y "~op~" that"),
			mixin("z "~op~" that")
			);
	}

	/++
		Binary operation on two $(D_PARAM CoordXYZ)s.
	+/
	CoordXYZ opBinary(string op)(CoordXYZ that) const
	{
		return CoordXYZ(
			mixin("this.x "~op~"that.x"),
			mixin("this.y "~op~"that.y"),
			mixin("this.z "~op~"that.z")
			);
	}

	/+
		Binary operation assign with a scalar. Applies that operation to each component.
	+/
	ref CoordXYZ opOpAssign(string op)(int that) const
	{
		mixin("x "~op~"= that;");
		mixin("y "~op~"= that;");
		mixin("z "~op~"= that;");
		return this;
	}

	/+
		Binary operation assign with another CoordXYZ. Applies the operation as three scalars.
	+/
	ref CoordXYZ opOpAssign(string op)(CoordXYZ that) /// ditto
	{
		mixin("this.x "~op~"= that.x;");
		mixin("this.y "~op~"= that.y;");
		mixin("this.z "~op~"= that.z;");
		return this;
	}

	string toString()
	{
		return format("(%d,%d,%d)", x, y, z);
	}
}

/***
	Structure to demarcate the top-down limits of an area in Minecraft. Holds four co-ordinates: west, east, north and south. Convention dictates that these should be chunk co-ordinates, but $(D_KEYWORD Extents) does no checking of this.

	Iteration semantics work on a half-open range basis — the north and west edges are included in the resultant co-ordinates, but the south and east edges are not. (See $(D_KEYWORD Extents.Range) for more.)
*/
struct Extents
{
	int west, east, north, south;

	/// Constructor from four co-ordinates.
	this(int w, int e, int n, int s)
	{
		this.west  = w;
		this.east  = e;
		this.north = n;
		this.south = s;
	}

	/// Constructor from a north-west and south-east co-ordinate pair.
	this(CoordXZ nw, CoordXZ se)
	{
		north = nw.z; west = nw.x;
		south = se.z; east = se.x;
	}

	/// Constructor-style static function returning an $(D_KEYWORD Extents) from a north-east and south-west co-ordinate pair.
	static Extents fromNESW(CoordXZ ne, CoordXZ sw)
	{
		return Extents(sw.x, ne.x, ne.z, sw.z);
	}

	/// Create and return a $(D_KEYWORD CoordXZ) representing the four corners of the extents.
	@property CoordXZ northWest() const { return CoordXZ(west, north); }
	@property CoordXZ northEast() const { return CoordXZ(east, north); } /// ditto
	@property CoordXZ southWest() const { return CoordXZ(west, south); } /// ditto
	@property CoordXZ southEast() const { return CoordXZ(east, south); } /// ditto

	/// Return the size of the Extents.
	@property uint width () const { return east  - west; }
	@property uint height() const { return south - north; }

	string toString() const
	{
		return "(Extents <%d, >%d, ^%d, v%d)".format(west, east, north, south);
	}

	/// Returns true iff $(D_KEYWORD west <= that.x < east) and $(D_KEYWORD north <= that.z < south).
	bool opBinaryRight(string op : "in")(CoordXZ that) const
	{
		return
		that.x >= west  && that.x < east &&
		that.z >= north && that.z < south;
	}

	/// Promotes $(D_KEYWORD this) to the minimum bounding box that contains both $(D_KEYWORD this) and $(D_KEYWORD that).
	ref Extents opOpAssign(string op : "+")(Extents that)
	{
		west  = min(west, that.west);
		east  = max(east, that.east);
		north = min(north, that.north);
		south = max(south, that.south);
		return this;
	}

	Extents opBinary(string op : "+")(Extents that) const
	{
		Extents r = this;
		r += that;
		return r;
	}

	invariant() {
		scope(failure) stderr.writefln("Extents invariant failed on <%d >%d ^%d v%d", west, east, north, south);
		assert(west <= east);
		assert(north <= south);
	}

	/// Range to iterate all points within the $(D_KEYWORD Extents) given.
	struct Range
	{
		this(Extents ex_)
		{
			ex = ex_;
			xz = CoordXZ(ex.west, ex.north);
		}

		@property Extents extents()
		{
			return ex;
		}

		@property CoordXZ front()
		in {
			assert(!this.empty);
		} body
		{
			return xz;
		}

		@property bool empty()
		{
			return xz.z >= ex.south;
		}

		void popFront()
		{
			++xz.x;
			if (xz.x >= ex.east) {
				++xz.z;
				xz.x = ex.west;
			}
		}

		@property Range save()
		{
			typeof(return) r = void;
			r.ex = this.ex;
			r.xz = this.xz;
			return r;
		}

		unittest
		{
			auto r = Extents(0, 3, 10, 12)[];
			assert(r.front == CoordXZ(0, 10));
			r.popFront();
			assert(r.front == CoordXZ(1, 10));
			r.popFront();
			assert(r.front == CoordXZ(2, 10));
			r.popFront();
			assert(r.front == CoordXZ(0, 11));
			r.popFront();
			assert(r.front == CoordXZ(1, 11));
			r.popFront();
			assert(r.front == CoordXZ(2, 11));
			r.popFront();
			
			assert(r.empty);
		}

		unittest {
			auto e = Extents(0, 10, -5, 5);
			auto r = e[];
			r.popFront();
			auto s = r.save;
			assert(s.extents == r.extents);
			assert(s.front == e.northWest + CoordXZ(1, 0));
		}

	private:
		Extents ex;
		CoordXZ xz;
	}

	Range opSlice()
	{
		return Range(this);
	}

	unittest
	{
		assert(Extents(0, 2, 0, 2) + Extents(1, 3, 1, 3) == Extents(0, 3, 0, 3));
		/* TODO:
		CoordXZ in Extents
		CoordXZ !in Extents
		*/

		Extents a = Extents(0, 9, 2, 4); // ctor
		Extents b = a; // copy ctor
		assert(b == a);
		b.south = -1;
		b = a; //assignment ctor
		assert(b == a);

		Extents c = Extents(CoordXZ(0, 1), CoordXZ(10, 11));
		assert(c == Extents(0, 10, 1, 11));
	}

	unittest
	{
		int w = -10, e = 10, n = -5, s = 5;
		Extents e1 = Extents(w, e, n, s), e2 = Extents(CoordXZ(w, n), CoordXZ(e, s));
		assert(e1 == e2);
	}
}

private import std.range : isForwardRange;
static assert(isForwardRange!(Extents.Range));
