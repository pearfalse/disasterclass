// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.filters.stoneage;
/++

	Very basic StoneAge filter for $(I Disasterclass)'s true purpose. This filter:
	$(UL
		$(LI converts cobblestone to mossy cobblestone;)
		$(LI converts plain stone to cobblestone;)
		$(LI converts all stone brick to plain stone.)
	)

+/

import disasterclass.chunk;
import disasterclass.parallel;
import disasterclass.vectors;
import disasterclass.data;
import disasterclass.support;

class StoneAgeContext : WTContext
{
	override void begin()
	{
		Chunk.seedThisThread(Chunk.rngSeed);
	}

	override void processChunk(Chunk c, ubyte pass)
	{
		//debug(dc13WriteChunk) stderr.writef("bsa %s", mCoord);

		// Filter thresholds for random numbers (these numbers themselves are pretty arbitrary)
		enum uint
		ThreshBrickToCracked = 0xaa000000U,
		ThreshBrickToMoss    = 0x18000000U,
		ThreshBrickToPlain   = 0x03000000U,
		ThreshPlainToCobble  = 0x88000000U,
		ThreshCobbleToMossy  = 0x1f000000U,
		ThreshRose           = 0x018a37afU,
		ThreshDandelion      = 0x07688184U,
		ThreshNoGrass        = 0x00418937U,
		Thresh99Percent      = 0xfd70a3d6U,

		// those numbers are quite similar, so we xor each result with a random number
		XorBrickToCracked    = 0x58e6852aU,
		XorBrickToMoss       = 0x2bda4cf3U,
		XorBrickToPlain      = 0xac86edbdU,
		XorPlainToCobble     = 0x9edc574eU,
		XorCobbleToMossy     = 0x5fae7f06U
		;

		//debug stderr.write(".");

		foreach (y_ ; 0..256) foreach (ubyte z ; 0..16) foreach (ubyte x ; 0..16) {
			ubyte y = cast(ubyte) y_;
			auto blk = c[x, y, z];

			uint draw = Chunk.rng.front;

			// degrade stone
			if (blk.id == BlockType.Cobblestone && (draw ^ XorCobbleToMossy) < ThreshCobbleToMossy) {
				c[x, y, z] = BlockType.Moss_Stone;
			}
			else if (blk.id == BlockType.Stone && (draw ^ XorPlainToCobble) < ThreshPlainToCobble) {
				c[x, y, z] = BlockType.Cobblestone;
			}
			else if (blk.id == BlockType.Stone_Bricks && (draw ^ XorBrickToPlain) < ThreshBrickToPlain) {
				c[x, y, z] = BlockType.Stone;
			}

			// remove light sources
			else if (blk.id == BlockType.Torch && draw < Thresh99Percent) {
				c[x, y, z] = BlockType.Air;
			}
			else if (blk.id == BlockType.Jack_o_Lantern) {
				c[x, y, z] = BlockIDAndData(BlockType.Pumpkin, blk.data);
			}

			else if (y < 255 && blk.id == BlockType.Grass_Block && c[x, y+1, z].id == BlockType.Air) {
				if (draw < ThreshRose) {
					c[x, cast(ubyte) (y+1u), z] = BlockType.Rose;
				}
				else if (draw < (ThreshRose + ThreshDandelion)) {
					c[x, cast(ubyte) (y+1u), z] = BlockType.Dandelion;
				}
				else {
					c[x, cast(ubyte) (y+1u), z] = BlockIDAndData(BlockType.Grass, cast(BlockData) 1u);
				}
			}

			Chunk.rng.popFront();
		}
		c.modified = true;

	}

}