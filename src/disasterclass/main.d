// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.main;

/// Rough-and-ready command-line interface.

import disasterclass.nbt;
import disasterclass.world;
import disasterclass.chunk;
import disasterclass.region;
import disasterclass.support;
import disasterclass.data;
import disasterclass.versioninfo;
import disasterclass.threads;

import disasterclass.filters.atlantis;

import std.file;
import std.stdio;
import std.exception;
import std.algorithm;
import std.range : lockstep;
import std.string;
import std.array : join, joiner, minimallyInitializedArray;
import std.format : formattedRead;
import std.conv;
import std.getopt;
import std.parallelism : totalCPUs;
import std.concurrency : send;

alias ExitCode function(string[]) CmdlineFunc;
immutable CmdlineFunc[string] cmds;
immutable CmdlineFunc[] cmdsWithoutWorld;

static this()
{
	CmdlineFunc[string] cmdstemp;

	// Standard functions
	cmdstemp["countchunks"] = &main_countchunks;
	cmdstemp["stats"      ] = &main_stats;
	cmdstemp["freshen"    ] = &main_freshen;

	// Chunk processors
	cmdstemp["stoneage"   ] = &main_stoneage;
	cmdstemp["dither"     ] = &main_dither;
	cmdstemp["cityscape"  ] = &main_cityscape;
	cmdstemp["australia"  ] = &main_australia;
	cmdstemp["atlantis"   ] = &main_atlantis;

	cmdstemp["querydata"] = &main_querydata;

	debug {
		cmdstemp["pokeregion"] = &main_pokeregion;
	}
	cmdstemp.rehash();
	cmds = assumeUnique(cmdstemp);

	cmdsWithoutWorld = [&main_querydata];
}

/// Each cmdline function returns one of these. This code is displayed to the user, as well as forming $(I Disasterclass)'s return code.
enum ExitCode : int
{
	Success = 0,
	BadCmdlineArgs,
	BadWorldPath,
	CorruptWorld,


	UserError = 126,
	InternalError = 127
}

class Options_t
{
	Dimension dimension = Dimension.Overworld;
	string worldPath;
	uint[string] cacheSizes, metrics;
	bool[string] itinerary;
	uint nThreads;
	uint rngSeed;

	void parseDimensionString(string option, string value)
	{
		debug stderr.writefln(q{Parsing "%s" into a dimension}, value);
		try {
			auto dNumber = to!byte(value);
			enforce(dNumber >= Dimension.Nether && dNumber <= Dimension.End, "Invalid dimension number %d".format(dNumber));
			dimension = cast(Dimension) dNumber;
			return;
		}
		catch (ConvException) { /* it wasn't a numeric input. okay, ignore. */ }

		switch (value.toLower()) {
			case "overworld": dimension = Dimension.Overworld; return;
			case "nether":    dimension = Dimension.Nether;    return;
			case "end":       dimension = Dimension.End;       return;
			default: throw new Exception("Invalid dimension: " ~ value);
		}
	}
}

Options_t Options;
private World mainWorld;

/// Entry point for the $(I Disasterclass) command-line app. Dispatches to a command.
int main(string[] args)
{
	Options = new Options_t;

	ExitCode r = ExitCode.InternalError;
	scope(exit) {
		writeln();
		if (r != ExitCode.Success) {
			string reason = [
			ExitCode.BadCmdlineArgs: "bad command line arguments",
			ExitCode.BadWorldPath: "invalid path to Minecraft world",
			ExitCode.CorruptWorld: "corrupted Minecraft world",
			ExitCode.UserError: "user error",
			ExitCode.InternalError: "internal error"
			].get(r, "unknown reason");
			writeln("Quitting Disasterclass due to ", reason);
		}
		else writeln("Success");
	}

	{
		scope string toPrint = "Disasterclass " ~ Version.String ~ ", " ~ Version.Platform;
		scope char[] toPrint2 = new char[toPrint.length];
		toPrint2[] = '=';
		writeln(toPrint, '\n', toPrint2, '\n');
	}

	if (args.length < 2) {
		stderr.write( format("No command specified. Try one of these: %s\n\n", join(cmds.byKey(), ", ")) );

		r = ExitCode.BadCmdlineArgs;
		return r;
	}

	string cmd = args[1];
	args = args[1..$];

	auto matchingFunc = cmd in cmds;
	if (!matchingFunc) {
		writefln("Command '%s' not recognised. Try one of these: %s\n\n", cmd, join(cmds.byKey(), ", "));
		r = ExitCode.BadCmdlineArgs;
		return r;
	}


	try {
		//debug stderr.writefln("Args before: %s", args);
		Options.nThreads = totalCPUs;
		getopt(args,
			std.getopt.config.caseInsensitive,
			"world", &Options.worldPath,
			"dimension", &Options.parseDimensionString,
			"cachesize", &Options.cacheSizes,
			"threads", &Options.nThreads,
			"rng-seed", &Options.rngSeed,
			"itinerary", &Options.itinerary,
			"metrics", &Options.metrics
			);
		//debug stderr.writefln("Args after: %s", args);

		try {
			if (cmdsWithoutWorld.countUntil(*matchingFunc) < 0) mainWorld = new World(Options.worldPath);
		}
		catch (FileException e) {
			stderr.writefln("Couldn't open world %s: %s", Options.worldPath, e.msg);
			return ExitCode.BadWorldPath;
		}

		//writefln("Will use up to %d %s.", Options.nThreads, Options.nThreads == 1 ? "thread" : "threads");

		r = (*matchingFunc)(args);
		if (Options.itinerary.get("relight", false)) {
			relightWorld();
		}
	}
	catch (Exception e)
	{
		debug {
			throw e;
		}
		else {
			stderr.writefln("Exception %s found: %s", e.classinfo.name, e);
			return ExitCode.UserError;
		}
	}
	catch (Error e)
	{
		debug {
			throw e;
		}
		else {
			stderr.writefln("Fatal error %s found: %s", e.classinfo.name, e);
			return ExitCode.InternalError;
		}
	}

	return r;
}

/++
	Counts the chunks in a world's overworld.

	Yep. That's all it does.

	Params:
		arg0 = Path to Minecraft world.
+/
ExitCode main_countchunks(string[] args)
{
	writefln("World: %s (%d chunks)", mainWorld.name, mainWorld.numberOfChunks());

	return ExitCode.Success;
}

/++
	Tallies up the number of blocks in a Minecraft world, and lists the results on stdout.

	Params:
		arg0 = Path to Minecraft world.
		arg1 = Dimension to check - $(I overworld), $(I nether) or $(I end).
+/
ExitCode main_stats(string[] args)
{
	Dimension dimension = Options.dimension;

	writefln("Examining the %s dimension of \"%s\" at %s.", dimension, mainWorld.name, Options.worldPath);
	writefln("Region contains %d chunks total.", mainWorld.numberOfChunks(dimension));
	writefln("Dimension extents (W,E,N,S): %s", mainWorld.extents(dimension));


	struct BlockCounts { WorkerTaskId taskId; immutable(ulong)[] blockCounts; }

	// stats contexts
	class StatsMTContext : MTContext
	{
		// this type lets us rearrange the block ids, to sort them later
		alias Tuple!(BlockID, "blockID", ulong, "count") Counts_t;

		this()
		{
			mCounts = new Counts_t[NBlockTypes];
			//mCounts = minimallyInitializedArray!(Counts_t[])(NBlockTypes);
			foreach (BlockID i, ref c ; mCounts) {
				c.blockID = i;
				c.count = 0UL;
			}
		}

		override void processMessage(Variant v)
		{
			debug stderr.writefln("StatsMTContext found message %s", v.type);
			BlockCounts* msg = v.peek!(BlockCounts);
			assert(msg);
			//mCounts[] += msg.blockCounts[];
			foreach (src, ref dst ; lockstep(msg.blockCounts[], mCounts)) {
				dst.count += src;
			}
		}

		private Counts_t[] mCounts;
	}

	class StatsContext : WTContext
	{
		ulong[NBlockTypes] blocks;

		override void processChunk(Chunk c, WorkerTaskId taskId, Tid)
		{
			debug(none) {
				stderr.writefln("[WT%d] [StatsContext] processChunk", taskId);
			}
			foreach (BlockID blk, BlockData data ; c) {
				++blocks[blk];
			}
		}

		override void cleanup(WorkerTaskId taskId, Tid parentTid)
		{
			debug(none) {
				stderr.writefln("[WT%d] [StatsContext] Sending final block counts", taskId);
			}
			parentTid.send(BlockCounts( taskId, blocks[].assumeUnique() ));
		}
	}

	scope ct = new StatsMTContext;
	auto result = runParallelTask(mainWorld, dimension, typeid(StatsContext), ct, Options.nThreads);

	immutable(StatsMTContext.Counts_t)[] counts = ct.mCounts[].sort!"a.count > b.count"().release().assumeUnique();

	writeln("Stats results:");
	bool foundSomeBlocks = false;
	ulong totalBlocks = reduce!"a + b.count"(0UL, counts); // don't include air, it skews the results

	foreach (pair ; counts) {

		if (pair.count == 0) continue;
		foundSomeBlocks = true;

		// clearer formatting
		string factor = null;
		if (pair.blockID != 0) {
			auto percentage = cast(double) pair.count / totalBlocks * 100;
			//debug stderr.writefln("%d / %d * 100 = %.2f", pair.count, totalBlocks, percentage);
			factor = " (%.04f%% of remaining blocks)".format(percentage);
		}
		writefln("%s (%d): %d%s", blockOrItemName(cast(BlockID) pair.blockID), pair.blockID, pair.count, factor);
		//debug stderr.writefln("totalBlocks: %d - %d = %d", totalBlocks, pair.count, totalBlocks - pair.count);
		totalBlocks -= pair.count; // update percentage to discount higher-count blocks that came before
	}
	writeln();
	if (result.skipped) {
		writefln("%d %s skipped.", result.skipped, result.skipped == 1 ? "chunk" : "chunks");
	} else {
		writeln("No chunks skipped.");
	} 
	if (foundSomeBlocks) writeln("\nPercentages do not include air blocks, since they skew the other numbers too much.");
	else writefln("No blocks found in \"%s\" > %s", mainWorld.name, dimension);

	return ExitCode.Success;	
}

/++
	Essentially, a command-line interface to $(D_CODE Region.findGapToWriteChunk). Not a lot of use if that function stays bug-free.
+/
debug ExitCode main_pokeregion(string[] args)
{
	writeln(
		"<pokeregion> For testing purposes only. Doesn't support Nether or End.\n"
		"\n"
		"Type three numbers (chunk X, chunk Z, comp'd chunk size in 4KiB sectors) and\n"
		"Disasterclass will tell you where it'd save it.\n"
		"Type q to quit."
		);

	int x, z; uint size;

	Lmain: while (true) {
		// parse cmdline

		stderr.write("> ");
		auto line = stdin.readln().stripLeft();
		if (!line.length) continue Lmain;
		if (line[$-1] == '\n') line = line[0..$-1];

		if (line == "q") break Lmain;

		try {
			if (line.formattedRead("%d", &x) == 0) goto LparseError;
			line = line.stripLeft();
			if (line.formattedRead("%d", &z) == 0) goto LparseError;
			line = line.stripLeft();
			if (line.formattedRead("%d", &size) == 0) goto LparseError;
		}
		catch (ConvException) {
			goto LparseError;
		}

		stderr.writef("%d, %d (%d sr): ", x, z, size);

		auto regionCoord = CoordXZ(x / 32, z / 32), subCoord = CoordXZ(x & 31, z & 31);

		Region region = mainWorld.mAllRegionsOverworld.get(regionCoord, null);
		if (region is null) {
			stderr.writefln("No region exists for %s - would write at 0x2000.", CoordXZ(x,z));
			continue Lmain;
		}

		auto foundRange = region.findGapToWriteChunk(subCoord, size * 4096);

		stderr.writefln("Found %s (offsets %x to %x in region %s)", foundRange, foundRange.front * 4096, foundRange.end * 4096, region.id);
		continue Lmain;

		LparseError:
		stderr.writefln("Parse error. Try again.");
		continue Lmain;	
	}

	return ExitCode.Success;
}

/++
	Interface to $(D_CODE Chunk.basicStoneAge). Transforms stone blocks in all chunks according to its simplistic rules.
+/
ExitCode main_stoneage(string[] args)
{
	// a VERY BASIC stoneage interface

	writefln("Seeding StoneAge twister with %d.", Options.rngSeed);
	Chunk.rngSeed = Options.rngSeed;

	//Chunk c = mainWorld.byRegion(Dimension.Overworld).front.byChunk.front;
	//c.basicStoneAge();

	class StoneAgeContext : WTContext
	{
		override void begin(WorkerTaskId taskId, Tid parentTid)
		{
			Chunk.seedThisThread(Chunk.rngSeed);
		}

		override void processChunk(Chunk c, WorkerTaskId taskId, Tid parentTid)
		{
			c.basicStoneAge();
			//if (Options.itinerary.get("relight", true)) c.relight();
		}
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(StoneAgeContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:stoneage]");

	return ExitCode.Success;
}

/++
	Forcibly re-commits all chunks back to the region, without changing their game data.
+/
ExitCode main_freshen(string[] args)
{

	foreach (region ; mainWorld.byRegion(Dimension.Overworld)) {
		stdout.writefln("Region %s (%d chunks)...", region.id, region.numberOfChunks); stdout.flush();
		foreach (chunkCoord ; region.byChunk) {
			auto chunkNBT = region.decompressChunk(chunkCoord.regionSubCoord);
			auto chunk = new Chunk(chunkCoord, Dimension.Overworld, chunkNBT);

			region.writeChunk(chunk.coord, chunk.flatten());

			destroy(chunk);
		}
	}

	return ExitCode.Success;
}

/++
	Checkerboards the world. Was invented to reduce compression efficiency and track down a very stealthy region bug.
+/
ExitCode main_dither(string[] args)
{

	class DitherContext : WTContext
	{
		override void processChunk(Chunk chunk, WorkerTaskId taskId, Tid parentTid)
		{
			chunk.dither();
		}
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(DitherContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:dither]");

	return ExitCode.Success;
}

/++
	Creates a dull, barren cityscape by turning all non-air blocks into stone.
+/
ExitCode main_cityscape(string[] args)
{
	class CityscapeContext : WTContext
	{
		override void processChunk(Chunk chunk, WorkerTaskId taskId, Tid parentTid)
		{
			chunk.cityscape();
		}
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(CityscapeContext), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[dc13:cityscape]");

	return ExitCode.Success;
}

ExitCode main_australia(string[] args)
{
	class AustraliaContext : WTContext
	{
		override void processChunk(Chunk chunk, WorkerTaskId, Tid)
		{
			chunk.australia();
		}
	}

	runParallelTask(mainWorld, Dimension.Overworld, typeid(AustraliaContext), null, Options.nThreads);

	// flip the player's Y position
	auto ynode = mainWorld.levelRootNode["Data"]["Player"]["Pos"][1];
	ynode.doubleValue = 255 - ynode.doubleValue;

	mainWorld.updateTimestamp();
	mainWorld.name = mainWorld.name.dup.reverse.assumeUnique();
	mainWorld.saveLevelDat("[DC: Australia]");

	return ExitCode.Success;
}

ExitCode main_atlantis(string[] args)
{
	enum uint DefaultCeilingGap = 8;	
	Atlantis.ceilingGap = min(Options.metrics.get("atlantis-ceiling-gap", DefaultCeilingGap), ubyte.max);

	runParallelTask(mainWorld, Dimension.Overworld, typeid(Atlantis.Context), null, Options.nThreads);

	mainWorld.updateTimestamp();
	mainWorld.saveLevelDat("[DC: Atlantis]");

	return ExitCode.Success;
}

ExitCode main_querydata(string[] args)
{
	write("Transparent blocks: ");
	foreach (value ; Blocks.byValue().filter!((b) => (b.flags & Flags.Transparent) != 0)().map!"a.name[]"().joiner(", ")) {
		write(value);
	}
	writeln("\n");

	return ExitCode.Success;
}

void relightWorld()
{
	// relight the world
	class RelightWTContext : WTContext
	{
		override void processChunk(Chunk c, WorkerTaskId _1, Tid _2)
		{
			c.relight2();
		}
	}

	runParallelTask(mainWorld, Options.dimension, typeid(RelightWTContext), null, Options.nThreads);
}
