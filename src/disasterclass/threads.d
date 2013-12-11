// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.threads;

/// Multicore thread dispatcher. Offers an interface to run per-chunk processes in parallel.

import disasterclass.world;
import disasterclass.support;
import disasterclass.chunk;
import disasterclass.cbuffer;
import disasterclass.nbt : isValidNBT;

import std.concurrency;
public import std.parallelism : totalCPUs;
import std.typecons;
import std.typetuple;
import std.traits : isSomeString;
import std.exception : assumeUnique;
import std.container : DList;
import std.algorithm ;
import std.range;
import std.stdio;
import core.memory : GC;
import core.time : dur;
import std.conv;

// for other modules that subclass [MW]TContext
public import std.concurrency : Tid;
public import std.variant : Variant;

alias ubyte WorkerTaskId;
enum ubyte MaxWorkerTaskId = 250;

package class MTContext
{
	/// Let subclasses deal with other message types.
	void processMessage(Variant v)
	{
		writefln("Manager thread received unknown message: %s", v);
	}

private:
	World world;
	Dimension dimension;
	Rebindable!(immutable ClassInfo) workerThreadContextType;

	ulong chunksProcessed = 0, chunksSkipped = 0;
}

package class WTContext
{
	/// Per-thread setup.
	void begin() { }

	/// Called whenever a chunk is created in local memory. Do $(B not) rely on $(D_KEYWORD chunkNeighbours) to contain meaningful data at this point.
	void prepareChunk(Chunk) { }

	/// Do task-specific processing by chunk.
	void processChunk(Chunk) { }

	/// Process any additional messages.
	void processMessage(Variant v)
	{
		writefln("Worker thread %d received unknown message: %s", mTaskId, v);
	}

	void cleanup() { }

protected:
	Tid mParentTid;
	WorkerTaskId mTaskId;
	ubyte mPass;
}

/// Find a neighbouring chunk with the supplied relative chunk co-ordinate. Returns null if no chunk found.
package Chunk getChunkAt(CoordXZ relCoord)
{
	assert(WT.thisChunk);

	CoordXZ absCoord = WT.thisChunk.coord + relCoord;
	if (absCoord == CoordXZ(0, 0)) return WT.thisChunk;

	auto r = chain(WT.leadingChunks, WT.laggingChunks).filter!"a !is null"().find!"a.coord == b"(absCoord);
	return r.empty ? null : r.front;
}

/// ditto
package Chunk getChunkAt(int x, int z)
{
	return getChunkAt(CoordXZ(x, z));
}

/// Update chunkNeighbours.
private void refillChunkNeighbours()
{
	assert(WT.thisChunk);
	chunkNeighbours[0..4] = null;
	chunkNeighbours[4] = WT.thisChunk;
	chunkNeighbours[5..$] = null;
	foreach (c ; chain(WT.leadingChunks[$-4 .. $], WT.laggingChunks[0 .. 4]).filter!"a !is null"()) {
		CoordXZ delta = c.coord - WT.thisChunk.coord;
		int index = (4 * delta.z) + delta.x + 5;
		if (index >= 0 && index < 9) {
			chunkNeighbours[cast(size_t) index] = c;
		}
	}
}

/// The immediate neighbours of the current chunk (in index order: NW, N, NE, W, C, E, SW, S, SE).
Chunk[9] chunkNeighbours;

/// Once a WT receives this, it will not receive any other messages until it declares itself as finished.
struct WorkerThreadToFinish { }

/***
	The launch point for worker threads. Wraps TLS data and exception propogation.

	Arguments:
	taskId_: This worker thread's conceptual task id.
	parentTid_: The tid of the manager thread. (Will be deprecated in Phobos 2.063)
	dimension_: The dimension of this extent.
	classInfo_: The typeid of the WTContext subclass managing the filter.
	rationExtent_: The extent 
***/
private void workerThread_main(WorkerTaskId taskId_, Tid parentTid_, Dimension dimension_, immutable(ClassInfo) classInfo_, Extents neighbourExtent_, Extents focusExtent_, ubyte pass)
{
	try {
		WT.taskId          = taskId_;
		WT.parentTid       = parentTid_;
		WT.dimension       = dimension_;
		WT.classInfo       = classInfo_;
		WT.neighbourExtent = neighbourExtent_;
		WT.focusExtent     = focusExtent_;

		workerThread_main2(pass);
	}
	catch (shared(Throwable) t) {
		stderr.writefln("[WT%d] EXCEPTION FOUND in workerThread_main2 (%s: %s at %s:%d)", WT.taskId, typeid(t), t.msg, t.file, t.line);
		WT.parentTid.prioritySend(t, thisTid);

		debug(dc13Threaded) {
			stderr.writefln("[WT%d] Sent %s; now closing", taskId, typeid(t));
		}
		return;

	}
	debug(dc13Threaded) {
		stderr.writefln("[WT%d] Succeeded", taskId);
	}
}

// Thread-local data used by worker threads.
private struct WT {
	static:
	/// Exposable task id.
	WorkerTaskId taskId;
	Tid parentTid; // n.b. will be deprecated by std.concurrency.ownerTid in Phobos 2.063
	Dimension dimension; /// Dimension of this world, since the World object is unavailable.
	WTContext context; /// Worker thread agent, managing this filter's ultimate job.
	Rebindable!(immutable ClassInfo) classInfo; /// The subclass of WTContext to make.
	Extents neighbourExtent, focusExtent; /// Extents to iterate over.
	size_t leadLagSize; /// In the N–S, E–W linear iteration, how much total bufferage (with thisChunk in the middle) is needed to guarantee that a 1-chunk border remains loaded?

	// it's an assembly line of chunks!
	/*
	outgoingChunk (in wtShiftChunks only) ← leadingChunks[] ← thisChunk ← laggingChunks[] ← checked-in chunks
	*/

	Chunk[] leadingChunks; // NW of current chunk, already processed
	Chunk thisChunk; // currently processing chunk
	Chunk[] laggingChunks; // SE of current chunk; not processed

	ulong
	cycleCount = 0,      /// Number of loop cycles the worker thread runs
	chunksProcessed = 0, /// Number of chunks successfully processed
	chunksSkipped = 0;   /// Number of chunks reverted due to error

}

/++
	Runs the first pass of a world's ration in a worker thread. Pass 1 involves all the ration's chunks, save for the edge ones where neighbours would be in a different ration.
+/
private void workerThread_main2(ubyte pass)
{
	debug(dc13Threaded) {
		stderr.writefln("[WT%d] Started main (WT.context object type: %s). Full extent: %s; focus extent: %s", WT.taskId, WT.classInfo, WT.neighbourExtent, WT.focusExtent);
	}

	// try making a WTContext
	WT.context = cast(WTContext) WT.classInfo.create();
	assert(WT.context, "Couldn't create WTContext descendent (%s)".format(WT.classInfo));

	// set member variables in WTContext object
	WT.context.mParentTid = WT.parentTid;
	WT.context.mTaskId    = WT.taskId;
	WT.context.mPass      = pass;

	WT.leadLagSize = (WT.neighbourExtent.width + 1) * NeighbourRadius;

	// prepare chunk lead/lag arrays
	WT.leadingChunks = new Chunk[WT.leadLagSize];
	WT.laggingChunks = new Chunk[WT.leadLagSize];

	// set the WTContext off
	WT.context.begin();

	bool iteratingOverArea = true;
	while (iteratingOverArea) {
		receive(
			(CoordXZ coord, immutable(ubyte)[] stream) {
				debug(dc13Threaded) stderr.writefln("[WT%d] Received chunk stream of %s", WT.taskId, coord);
				try {
					auto newChunk = new Chunk(coord, WT.dimension, stream);
					WT.context.prepareChunk(newChunk);
					WT.laggingChunks[$-1] = newChunk;
				}
				catch (Exception e) {
					stderr.writefln("[WT%d] Couldn't create chunk %s: %s", WT.taskId, coord, e.msg);
					WT.laggingChunks[$-1] = null;
				}
			},

			(WorkerThreadToFinish _) {
				iteratingOverArea = false;
				debug(dc13Threaded) stderr.writefln("[WT%d] told to finish", WT.taskId);
			},

			(Variant v) {
				WT.context.processMessage(v);
			}
			);

		if (WT.thisChunk && WT.thisChunk.coord in WT.focusExtent) {
			debug(dc13Threaded) stderr.writefln("[WT%d] Processing chunk %s...", WT.taskId, WT.thisChunk.coord);
			refillChunkNeighbours();
			try {
				WT.context.processChunk(WT.thisChunk);
				++WT.chunksProcessed;
			}
			catch (Exception e) {
				writefln("Exception (%s) in worker thread %d when processing chunk %s: %s", typeid(e), WT.taskId, WT.thisChunk.coord, e.msg);
				++WT.chunksSkipped;
			}
		}

		// shift all chunks one stop up the aforementioned assembly line

		bool didSendChunk = false;

		// send off the NW neighbour before it goes out of range
		Chunk outgoingChunk = WT.leadingChunks[0];// push out earliest leading chunk
		if (outgoingChunk !is null) {
			immutable(ubyte)[] chunkStream = outgoingChunk.modified ? outgoingChunk.flatten().assumeUnique() : null;
			debug(dc13Threaded) stderr.writefln("[WT%d] Sending chunk %s back to MT (modified: %s)", WT.taskId, outgoingChunk.coord, chunkStream !is null);
			WT.parentTid.send(WT.taskId, outgoingChunk.coord, chunkStream);
			didSendChunk = true;
		} else {
			debug(dc13Threaded) stderr.writefln("[WT%d] outgoing chunk is null", WT.taskId);
		}

		debug(dc13Threaded) {
			auto leadingNull = reduce!"a + 1"(0u, WT.leadingChunks.filter!"a is null"());
			auto laggingNull = reduce!"a + 1"(0u, WT.laggingChunks.filter!"a is null"());
			stderr.writefln("[WT%d] NULL COUNT: (leading=%d, this=%s, lagging=%d)", WT.taskId, leadingNull, WT.thisChunk is null, laggingNull);
		}

		if (!didSendChunk) {
			// no chunk sent back; there are still gaps in the buffer
			assert(chain(WT.leadingChunks, [WT.thisChunk], WT.laggingChunks[0..$-1]).any!"a is null"());
			debug(dc13Threaded) stderr.writefln("[WT%d] Another chunk requested to warm the cache (%d gap(s) in WT.laggingChunks)", WT.taskId, reduce!"a + 1"(0u, WT.laggingChunks[0..$-1].filter!"a is null"()) );
			WT.parentTid.send(WT.taskId, true);
		}

		// Chunk shift
		debug(dc13Threaded) stderr.writefln("[WT%d] Shifting chunks", WT.taskId);
		copy(WT.leadingChunks[1 .. $], WT.leadingChunks[0 .. ($-1)]);
		WT.leadingChunks[$-1] = WT.thisChunk;

		WT.thisChunk = WT.laggingChunks[0]; // earliest lagging chunk is promoted to the spotlight

		copy(WT.laggingChunks[1 .. $], WT.laggingChunks[0 .. ($-1)]);
		WT.laggingChunks[$-1] = null;

		++WT.cycleCount;
	}

	// there are lagging chunks still to process (as well as the new WT.thisChunk)
	foreach (chunk ; WT.laggingChunks.chain([WT.thisChunk]).filter!"a !is null"()) {
		// process the lagging chunks that remain
		try {
			WT.context.processChunk(chunk);
			immutable(ubyte)[] chunkStream = chunk.modified ? chunk.flatten().assumeUnique() : null;
			debug(dc13Threaded) stderr.writefln("[WT%d cleanup] Sending lagging chunk %s back to WT (modified: %s)", WT.taskId, chunk.coord, chunk.modified);
			WT.parentTid.send(WT.taskId, chunk.coord, chunkStream);
			++WT.chunksProcessed;
		}
		catch (Exception e) {
			++WT.chunksSkipped;
			stderr.writefln("[WT%d] Couldn't process chunk %s: %s", WT.taskId, chunk.coord, e.msg);
		}
	}

	foreach (chunk ; WT.leadingChunks.chain([WT.thisChunk]).filter!"a !is null"()) {
		immutable(ubyte)[] chunkStream = chunk.modified ? chunk.flatten().assumeUnique() : null;
		debug(dc13Threaded) stderr.writefln("[WT%d cleanup] Sending leading chunk %s back to WT (modified: %s)", WT.taskId, chunk.coord, chunk.modified);
		WT.parentTid.send(WT.taskId, chunk.coord, chunkStream);
		++WT.chunksProcessed;
	}

	WT.context.cleanup();

	WT.parentTid.send(WT.taskId, WT.chunksProcessed, WT.chunksSkipped); // done

	debug {
		stderr.writefln("WT%d complete! %d loop cycles, %d chunks processed, %d chunks skipped", WT.taskId, WT.cycleCount, WT.chunksProcessed, WT.chunksSkipped);
	}
}

/// Stores data about worker threads. Lives on the manager thread.
private final class WorkerThreadAgent
{
	this(WorkerTaskId ti)
	{
		taskId = ti;

		assert(ti !in allAgents);
		allAgents[ti] = this;
	}

	void remove()
	{
		allAgents.remove(this.taskId);
	}

	@property bool active()
	{
		return (this.taskId in allAgents) !is null;
	}

	override hash_t toHash() const { return taskId; }
	override string toString() const { return "WT" ~ taskId.to!string(); }
	override int opCmp(Object o)
	{
		auto o2 = cast(WorkerThreadAgent) o;
		assert(o2);
		if (this.taskId < o2.taskId) return -1;
		if (this.taskId > o2.taskId) return 1;
		return 0;
	}

	void spawnChild(ubyte pass, ubyte neighbourRange, Dimension d, immutable(ClassInfo) wtctxInfo, Extents focus)
	{
		debug(dc13Threaded) stderr.writefln("Creating worker thread %d with %s", taskId, areaRange.extents);
		tid = spawnLinked(&workerThread_main, this.taskId, thisTid, d, wtctxInfo, areaRange.extents, focus, pass);
		readyForChunk = true;
	}

	WorkerTaskId taskId;
	Tid tid;
	bool readyForChunk;
	//bool flushingBuffers = false;
	enum State : ubyte {
		Inactive = 0,
		Active = 1,
		Flushing = 2,
		Done = 3
	}
	State state;
	ulong checkedOutChunks = 0;
	Nullable!(Extents.Range) areaRange;
	Extents focusExtent;

	static WorkerThreadAgent[WorkerTaskId] allAgents;
	static WorkerThreadAgent opIndex(size_t i)
	{
		assert(i <= WorkerTaskId.max);
		return allAgents.get(cast(WorkerTaskId) i, null);
	}
}

/// Maximum neighbour radius. Hardcoded for now.
enum ubyte NeighbourRadius = 1;
alias Tuple!(ulong, "processed", ulong, "skipped") ParallelTaskResult;
ParallelTaskResult runParallelTask(World world, Dimension dimension, ClassInfo wtctxInfo, MTContext ctx = null, uint nThreads = 1)
{
	Extents worldExtent = world.chunkExtents(dimension);

	if (ctx is null) ctx = new MTContext;

	ctx.world = world;
	ctx.dimension = dimension;
	ctx.workerThreadContextType = cast(immutable ClassInfo) wtctxInfo;

	debug(dc13Threaded) {
		stderr.writefln("World %s: %d chunks, size %s", world.name, world.numberOfChunks(dimension), worldExtent);
	}

	// nSplits: number of sections the world is split into.
	uint nSplits = max(nThreads, 1); // in most cases, this is true
	debug(dc13Threaded) stderr.writefln("nSplits 1st pass: %d", nSplits);
	/*
		There are certain restrictions on splitting the world:
		• Only split down vertical lines. No horizontal split boundaries.
		• The following must hold true:
			(let n = neighbour radius. let d = 2n + 1)
			• world width >= d
			• number of rationing strips <= floor(world width / d)
	*/
	enum uint NeighbourDiameter = 2 * NeighbourRadius + 1;
	if (worldExtent.width < NeighbourDiameter) {
		// world is too small to split
		nSplits = 1;
		debug(dc13Threaded) stderr.writefln("World too small to split");
	}
	else {
		nSplits = min(nSplits, worldExtent.width / NeighbourDiameter, typeof(nSplits).max - 1); // this fraction is allowed to round down
		debug(dc13Threaded) stderr.writefln("nSplits 2nd pass: %d", nSplits);
	}

	// find latitude boundaries between chunks (includes west-most and east-most points)
	auto boundaries = iota(nSplits + 1)
	.map!((s) => s / cast(real) (nSplits) * worldExtent.width)()
	.map!((a) => cast(int) (a) + worldExtent.west)()
	.array();
	assert(boundaries.length == nSplits + 1);

	debug(dc13Threaded) stderr.writefln("Boundaries: %s", boundaries);

	// set up worker agents
	WorkerTaskId rollingTaskId = 1;
	foreach (i ; 0..nSplits) {
		Extents e;
		e.north = worldExtent.north;
		e.south = worldExtent.south;
		e.west = boundaries[i];
		e.east = boundaries[i + 1];
		auto agent = new WorkerThreadAgent(rollingTaskId++);
		agent.areaRange = e[];
	}
	WorkerThreadAgent.allAgents.rehash();
	debug(dc13Threaded) stderr.writefln("%d worker thread agents.", WorkerThreadAgent.allAgents.length);

	// pass 1: the core of each split
	runPass(1, ctx);

	// pass 2: the boundaries
	// remove the highest agent; there's one less thread here
	WorkerThreadAgent.allAgents.remove(cast(WorkerTaskId) nSplits);

	foreach (agent ; WorkerThreadAgent.allAgents.byValue()) {
		debug(dc13Threaded) stderr.writefln("Preparing worker agent %d (%d boundaries)", agent.taskId, boundaries.length);
		auto ex = Extents(
		/* west  */ boundaries[agent.taskId] - (NeighbourRadius * 2),
		/* east  */ boundaries[agent.taskId] + (NeighbourRadius * 2),
		/* north */ worldExtent.north,
		/* south */ worldExtent.south
		);
		debug(dc13Threaded) stderr.writefln("Extents range for WT%d will be set to %s", agent.taskId, ex);
		agent.areaRange = ex[];
	}
	
	runPass(2, ctx);

	// clear allAgents for the next run
	WorkerThreadAgent.allAgents = null;

	return ParallelTaskResult(ctx.chunksProcessed, ctx.chunksSkipped);
}

void runPass(ubyte pass, MTContext ctx)
{
	writefln("--- Beginning pass %d", pass);
	auto worldExtents = ctx.world.chunkExtents(ctx.dimension);

	WorkerThreadAgent[WorkerTaskId] passAgents = WorkerThreadAgent.allAgents.dup();
	foreach (agent ; passAgents.byValue()) {
		agent.checkedOutChunks = 0;
		agent.state = WorkerThreadAgent.State.Active;
		agent.readyForChunk = true;
		assert(!agent.areaRange.isNull);
		Extents focus = agent.areaRange.extents;
		if (focus.west != worldExtents.west) focus.west += NeighbourRadius;
		if (focus.east != worldExtents.east) focus.east -= NeighbourRadius;
		agent.spawnChild(pass, NeighbourRadius, ctx.dimension, ctx.workerThreadContextType, focus);
	}

	while (passAgents.length > 0) {

		debug(dc13Threaded) stderr.writefln("[MT] Iterating for agent(s) %s", passAgents.byKey().map!"a.to!string()"().join(", "));

		foreach (agent ; passAgents.byValue().filter!((a) => a.state == WorkerThreadAgent.State.Active && a.readyForChunk)()) {
			//debug(dc13Threaded) stderr.writefln("Foreach cycle: agent %d", agent.taskId);
			immutable(ubyte)[] chunkStream = null;
			while (!agent.areaRange.empty) {
				CoordXZ coord = agent.areaRange.front;
				//debug(dc13Threaded) stderr.writefln("[MT] Testing coord %s...", coord);
				chunkStream = ctx.world.loadChunkNBT(coord, ctx.dimension).assumeUnique();
				
				if (chunkStream) {
					debug(dc13Threaded) stderr.writefln("[MT] Sending chunk %s to worker thread %s", coord, agent.taskId);
					agent.tid.send(coord, chunkStream);
					++agent.checkedOutChunks;
					agent.readyForChunk = false;
					agent.areaRange.popFront();
					break;
				}

				agent.areaRange.popFront();
			}

			assert(!agent.areaRange.isNull);
			if (agent.areaRange.empty) {

				agent.tid.send(WorkerThreadToFinish());
				agent.state = WorkerThreadAgent.State.Flushing;
			}
		}

		receive(
			(WorkerTaskId taskId, CoordXZ coord, immutable(ubyte)[] chunkStream) {
				// a chunk came back
				//assert(WorkerThreadAgent[taskId].readyForChunk == false);
				debug(dc13Threaded) stderr.writefln("[MT] Chunk %s returned from WT%d (modified: %s)", coord, taskId, chunkStream !is null);
				if (chunkStream) ctx.world.saveChunkNBT(coord, chunkStream, ctx.dimension);

				auto agent = WorkerThreadAgent[taskId];
				--agent.checkedOutChunks;
				if (agent.state == WorkerThreadAgent.State.Active) agent.readyForChunk = true;
				if (agent.state == WorkerThreadAgent.State.Flushing && agent.checkedOutChunks == 0) {
					debug(dc13Threaded) stderr.writefln("[MT] Closing agent for WT%d; last outstanding chunk returned", agent.taskId);
					agent.state = WorkerThreadAgent.State.Done;
				}
			},

			(WorkerTaskId taskId, bool sbt) {
				assert(sbt);
				passAgents[taskId].readyForChunk = true;
			},

			(WorkerTaskId taskId, ulong processed, ulong skipped) {
				debug(dc13Threaded) stderr.writefln("[MT] Worker thread %d completed", taskId);
				ctx.chunksProcessed += processed;
				ctx.chunksSkipped   += skipped;

				// worker thread is complete
				auto agent = passAgents[taskId];
				debug(dc13Threaded) stderr.writefln("[MT] Worker thread %d closed with %d checkouts outstanding (agent state: %s)", taskId, agent.checkedOutChunks, agent.state);
				if (agent.state == WorkerThreadAgent.State.Done) {
					agent.tid = Tid.init;
					agent.areaRange.nullify();
					passAgents.remove(taskId);
				}
			},

			(LinkTerminated _) { },

			(Variant v) {
				if (ctx) ctx.processMessage(v);
			}
		);
	} // while (passAgents.length > 0)

	// handle remaining messages
	while (receiveTimeout(dur!"seconds"(0),
		(LinkTerminated _) { },
		(Variant v) { if (ctx) ctx.processMessage(v); }
	)) {}

	debug(dc13Threaded) stderr.writeln("[MT] ALL WORKER THREADS COMPLETE. Setting agent states to Inactive.");
	foreach (agent ; WorkerThreadAgent.allAgents) {
		agent.state = WorkerThreadAgent.State.Inactive;
	}
}

