// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.filters.atlantis;

/// The «Atlantis» filter buries a world underground by adding a layer of stone above all chunks.

/*
Atlantis currently doesn't do any ceiling smoothing, or cross-chunk relaxation of its generated caves — two things that are planned as future improvements.
*/

import disasterclass.vectors;
import disasterclass.chunk;
import disasterclass.parallel;
import disasterclass.data;

import std.stdio;
import std.range;
import std.typecons;
import std.algorithm;

struct Atlantis
{
	alias XZPlane = Chunk.BlockArray!(ubyte, Chunk.Length, 1, Chunk.Length);
	alias Data = Tuple!(XZPlane*, "lowest", XZPlane*, "highest");

	class Context : WTContext
	{
		override void begin()
		{
			mCeilingGap = Atlantis.ceilingGap;
		}

		override void prepareChunk(Chunk chunk, ubyte pass)
		{
			auto lowest = new Chunk.BlockArray!(ubyte, Chunk.Length, 1, Chunk.Length)(); // to match XZ plane of chunk
			// set lowest to be the maximum Y coord of any non-air block
			foreach (y ; 0..Chunk.Height) foreach (z ; 0..Chunk.Length) foreach (x ; 0..Chunk.Length) {
				if (chunk.blocks[x, y, z] != BlockType.Air && y > (*lowest)[x, 0, z]) (*lowest)[x, 0, z] = cast(ubyte) y;
			}
			chunk.customData[&Atlantis.run] = Atlantis.Data(lowest, new Atlantis.XZPlane);
		}

		override void processChunk(Chunk chunk, ubyte pass)
		{
			Atlantis.run(chunk, mCeilingGap);
		}

	private:
		ubyte mCeilingGap;
		
	}

	static shared ubyte ceilingGap;

	static void run(Chunk c, ubyte ceilingGap)
	{
		// ensure this and each neighbour has at least the prep data
		debug foreach (cn ; chunkNeighbours[].filter!"a !is null"()) {
			assert(cn.customData[&run].hasValue, "chunk custom Atlantis data doesn't exist");
			assert(cn.customData[&run].peek!(Atlantis.Data)() !is null, "chunk custom data in atlantis slot exists, but is wrong type");
		}

		//debug stderr.writef("{ATL1 lowest lowest = %d}, ", reduce!min(lowest.array[]));
		assert(&run in c.customData, "custom Atlantis.Data not added for chunk %s".format(c.coord));
		assert(c.customData[&run].peek!(Atlantis.Data)(), "custom Atlantis data wrong type");
		auto data = c.customData[&run].get!(Atlantis.Data)();
		assert(data.lowest, "lowest is null");
		assert(data.highest, "highest is null");

		// set highest to whatever it takes to get full coverage
		foreach (byte z ; 0..Chunk.Length) foreach (byte x ; 0..Chunk.Length) {
			// the padding creates a potential mess of off-by-one issues, so do be careful
			(*data.highest)[x, 0, z] = max(
				(*data.lowest)[x           , 0, z], // this
				(*data.lowest)[max(x-1, 0 ), 0, z], // x - 1
				(*data.lowest)[min(x+1, 15), 0, z], // x + 1
				(*data.lowest)[x           , 0, max(z-1, 0 )], // z - 1
				(*data.lowest)[x           , 0, min(z+1, 15)]  // z + 1
				);

		}

		//debug stderr.writef("{ATLANTIS %d-%d %s}, ", reduce!min(0, lowest.array[]), reduce!max(0, highest.array[]), c.coord);

		// cover with stone
		foreach (xz, l, h ; zip(Extents(0, Chunk.Length, 0, Chunk.Length)[], data.lowest.array[], data.highest.array[])) {
			auto yStone1 = min(l + ceilingGap, Chunk.Height), yStone2 = min(h + ceilingGap, Chunk.Height);
			foreach (y ; yStone1..(yStone2+1)) {
				c.blocks[xz.x, y, xz.z] = BlockType.Stone;
				c.blockData[xz.x, y, xz.z] = 0;
			}
		}


		c.modified = true;
	}
}