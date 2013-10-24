// Written in the D programming language.

/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

module disasterclass.nbt;

/// Manage, encode and decode NBT nodes.

import disasterclass.support;

import std.exception;
import std.stdio;
import std.array : join;
import std.string;
import std.range;
import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : read;
import std.algorithm : map, reduce, any;
import std.traits : isIntegral;
import std.typetuple;
import std.math;

/// IDs for NBT types as specified in $(LINK2 http://www.minecraftwiki.net/wiki/NBT_Format, the documentation). Includes $(D_KEYWORD TAG__Last) as a special terminator value.
enum TagID : ubyte {
	TAG_End = 0,
	TAG_Byte = 1,
	TAG_Short = 2,
	TAG_Int = 3,
	TAG_Long = 4,
	TAG_Float = 5,
	TAG_Double = 6,
	TAG_Byte_Array = 7,
	TAG_String = 8,
	TAG_List = 9,
	TAG_Compound = 10,
	TAG_Int_Array = 11,
	TAG__Last
}

immutable string[TagID.TAG__Last] humanTagTypes = [
	"end", "byte", "short", "int", "long",
	"float", "double",
	"byte array", "string",
	"list", "compound", "int array"
	];

// Map TagIDs to their value types. Used in initialising constructor.
private alias TypeTuple!(void, byte, short, int, long, float, double, byte[], string, NBTNode[], NBTNode[string], int[], void) _TypeForTagID;

/***
	Class to represent a single node in an NBT tree. The node value is selected according to the tag id, without reallocation.

	Accessors and overloaded index operators are provided to access values with type checking, as well as unchecked access for maximum performance (and safety from memory corruption is up to you).
*/
class NBTNode
{
	NBTNode parent;
	TagID tagID;
	string name;

	/***
		Encapsulates everything about a TAG_List and its child nodes.
	*/
	struct ListValue_t {
		NBTNode[] nbtnodes; /// Array of list's contents. $(D_PSYMBOL ListValue_t) is aliased to this.
		TagID subnodeTagID; /// The $(D_KEYWORD TagID) that all subnodes conform to.
		alias nbtnodes this;
	}

	/// Index this for raw, unchecked access. But only if you really, $(I really) have to.
	union Value {
		byte byteValue;
		short shortValue;
		int intValue;
		long longValue;
		float floatValue;
		double doubleValue;
		byte[] byteArrayValue;
		string stringValue;

		ListValue_t listValue;
		NBTNode[string] compoundValue;
		int[] intArrayValue;
	}
	Value value;

	// Accessors --------------------------------------------------------------

	private final void tagIDEnforce(string s, TagID t) const
	{
		//enforce(this.tagID == t, "Tag %s is not %s; can't retrieve %s".format(this.tagID, t, s));
		enforce(this.tagID == t, "Tag %s is not %s; can't retrieve %s".format(this.tagID, t, s));
	}

	/***
		Returns a TAG_Byte value.

		Throws: DisasterclassException if the node is not of type TAG_Byte.
	*/
	@property final byte byteValue()
	{
		tagIDEnforce("byteValue", TagID.TAG_Byte);
		return value.byteValue;
	}

	/***
		Returns a TAG_Short value.

		Throws: DisasterclassException if the node is not of type TAG_Short.
	*/
	@property final short shortValue()
	{
		tagIDEnforce("shortValue", TagID.TAG_Short);
		return value.shortValue;
	}

	/***
		Returns a TAG_Int value.

		Throws: DisasterclassException if the node is not of type TAG_Int.
	*/
	@property final int intValue()
	{
		tagIDEnforce("intValue", TagID.TAG_Int);
		return value.intValue;
	}

	/***
		Returns a TAG_Long value.

		Throws: DisasterclassException if the node is not of type TAG_Long.
	*/
	@property final long longValue()
	{
		tagIDEnforce("longValue", TagID.TAG_Long);
		return value.longValue;
	}

	/***
		Returns a TAG_Float value.

		Throws: DisasterclassException if the node is not of type TAG_Float.
	*/
	@property final float floatValue()
	{
		tagIDEnforce("floatValue", TagID.TAG_Float);
		return value.floatValue;
	}

	/***
		Returns a TAG_Double value.

		Throws: DisasterclassException if the node is not of type TAG_Double.
	*/
	@property final double doubleValue()
	{
		tagIDEnforce("doubleValue", TagID.TAG_Double);
		return value.doubleValue;
	}

	/***
		Returns a TAG_String value.

		Throws: DisasterclassException if the node is not of type TAG_String.
	*/
	@property final string stringValue()
	{
		tagIDEnforce("stringValue", TagID.TAG_String);
		return value.stringValue;
	}

	/***
		Returns a TAG_ByteArray value.

		Throws: DisasterclassException if the node is not of type TAG_ByteArray.
	*/
	@property final inout(byte)[] byteArrayValue() inout
	{
		tagIDEnforce("byteArrayValue", TagID.TAG_Byte_Array);
		return value.byteArrayValue;
	}

	/***
		Returns a TAG_IntArray value.

		Throws: DisasterclassException if the node is not of type TAG_IntArray.
	*/
	@property final inout(int)[] intArrayValue() inout
	{
		tagIDEnforce("intArrayValue", TagID.TAG_Int_Array);
		return value.intArrayValue;
	}

	/***
		Returns a TAG_List value.

		Throws: DisasterclassException if the node is not of type TAG_List.
	*/
	@property final ref ListValue_t listValue()
	{
		tagIDEnforce("listValue", TagID.TAG_List);
		return value.listValue;
	}

	/***
		Returns a TAG_Compound value.

		Throws: DisasterclassException if the node is not of type TAG_Compound.
	*/
	@property final NBTNode[string] compoundValue()
	{
		tagIDEnforce("compoundValue", TagID.TAG_Compound);
		return value.compoundValue;
	}

	/***
		Returns a TAG_Byte_Array value, but as an array of unsigned bytes.

		Throws: DisasterclassException if the node is not of type TAG_Byte_Array.
	*/
	@property final inout(ubyte)[] ubyteArrayValue() inout
	{
		return cast(inout(ubyte)[]) this.byteArrayValue;
	}

	/***
		Returns a TAG_Int_Array value, but as an array of unsigned ints.

		Throws: DisasterclassException if the node is not of type TAG_Int_Array.
	*/
	@property final inout(uint)[] uintArrayValue() inout
	{
		return cast(inout(uint)[]) this.intArrayValue;
	}

	// ----------------------------------------------------------------------------------
	// Setters
	// ----------------------------------------------------------------------------------

	@property final byte byteValue(byte nv)
	{
		tagID = TagID.TAG_Byte;
		return (value.byteValue = nv);
	}

	@property final short shortValue(short nv)
	{
		tagID = TagID.TAG_Short;
		return (value.shortValue = nv);
	}

	@property final int intValue(int nv)
	{
		tagID = TagID.TAG_Int;
		return (value.intValue = nv);
	}

	@property final long longValue(long nv)
	{
		tagID = TagID.TAG_Long;
		return (value.longValue = nv);
	}

	@property final float floatValue(float nv)
	{
		tagID = TagID.TAG_Float;
		return (value.floatValue = nv);
	}

	@property final double doubleValue(double nv)
	{
		tagID = TagID.TAG_Double;
		return (value.doubleValue = nv);
	}

	@property final byte[] byteArrayValue(byte[] nv)
	{
		tagID = TagID.TAG_Byte_Array;
		return (value.byteArrayValue = nv);
	}

	@property final string stringValue(string nv)
	{
		tagID = TagID.TAG_String;
		return (value.stringValue = nv);
	};

	@property final NBTNode[string] compoundValue(NBTNode[string] nv)
	{
		tagID = TagID.TAG_Compound;
		return (value.compoundValue = nv);
	}

	@property final int[] intArrayValue(int[] nv)
	{
		tagID = TagID.TAG_Int_Array;
		return (value.intArrayValue = nv);
	}

	@property final ref ListValue_t listValue(NBTNode[] nv)
	{
		TagID checkTagIDConsistency()
		{
			if (!nv.length) return TagID.TAG_Byte; // no checking needs to be done
			assert(nv[0]); // no nulls please
			TagID ti = nv[0].tagID;
			// now ensure all other nodes match this
			debug foreach (i, node ; nv) {
				assert(node);
				assert(node.tagID == ti, "array node %d doesn't match opening tag id %s".format(i, ti));
			}
			return ti;
		}

		TagID listMemberTags = checkTagIDConsistency();
		tagID = TagID.TAG_List;
		value.listValue.subnodeTagID = listMemberTags;
		value.listValue.nbtnodes = nv;
		return value.listValue;
	}

	private uint _childPayloadSize; // this is how list and compound sub-tags propogate their calculated size up to their parent

	/***
		Construct an NBTNode tree from the provided array. In most cases, you should not need to set $(D_PARAM parent) yourself.
	*/
	this(const(ubyte)[] data, NBTNode parent = null)
	{
		// TODO: properly validate level_dat as NBT data
		enforce(data.length, "Tried to create an NBT tree from empty data");
		enforce(data[0] < TagID.TAG__Last, "Invalid tag ID");

		this.parent = parent;
		tagID = cast(TagID) data[0];

		auto nameLength = bigEndianDynamicToNative!ushort(data[1..3]);
		//stderr.writefln("nameLength: %d", nameLength);
		this.name = (cast(const(char)[]) data[3..nameLength+3]).idup;
		//stderr.writeln("Tag name: ", this.name);

		typeof(data) payload = data[nameLength+3 .. $]; // payload of nbt tag (start only; end may well overflow into subsequent tags)
		//debug stderr.writefln("data.ptr = %x, payload.ptr = %x", data.ptr, payload.ptr);
		this._decodePayload(payload);
	}

	/// Create a new empty NBTNode of type TAG_Byte.
	this()
	{
		this.tagID = TagID.TAG_Byte;
	}

	/// Returns a lower-case human-readable version of this node's tag types.
	@property final string humanTagType() const
	{
		return humanTagTypes[this.tagID];
	}

	/***
		Convenience function to deference a TAG_Compound.

		Throws: DisasterclassException if the node is not of type TAG_Compound.
	*/
	NBTNode opIndex(in char[] ckey)
	{
		enforce(this.tagID == TagID.TAG_Compound, format("Node \"%s\" is %s, not %s", this.name, this.humanTagType, humanTagTypes[TagID.TAG_Compound]));
		auto inResult = ckey in this.value.compoundValue;
		enforce(inResult, format("Element \"%s\" not in compound \"%s\"", ckey, this.name));
		return *inResult;
	}

	/***
		Convenience function to set a TAG_Compound value.

		Throws: Exception is the node is not of type TAG_Compound.
	*/
	ref NBTNode opIndexAssign(NBTNode value, in char[] ckey)
	{
		enforce(this.tagID == TagID.TAG_Compound, format("Node \"%s\" is %s, not %s", this.name, this.humanTagType, humanTagTypes[TagID.TAG_Compound]));

		auto key = ckey.idup;

		this.value.compoundValue[key] = value;
		value.name = key;
		return this;
	}

	/***
		Convenience function to deference a TAG_List.

		Throws: DisasterclassException if the node is not of type TAG_List.
	*/
	NBTNode opIndex(size_t i)
	{
		enforce(this.tagID == TagID.TAG_List, format("Element \"%s\" is %s, not %s", this.name, this.humanTagType, humanTagTypes[TagID.TAG_List]));
		enforce(i >= 0 && i < this.value.listValue.length, format("Index %d is out of bounds for list \"%s\"", i, this.name));
		return this.value.listValue[i];
	}

	invariant()
	{
		if (tagID == TagID.TAG_Compound) {
			assert(this.value.compoundValue.byKey().any!"a is null"() == false, "Null keys in compound value");
		}
	}

	/***
		Returns the memory footprint (in bytes) of an $(D_KEYWORD NBTNode) and its children. This number should be treated as approximate.

		Bugs: $(D_PSYMBOL memoryFootprint) does not check for cyclic references, although $(D_KEYWORD nbt) will never make them itself.
	*/
	@property final size_t memoryFootprint() const
	{
		size_t f = this.sizeof;
		switch (tagID) {
			case TagID.TAG_Byte_Array:
			f += value.byteArrayValue.length;
			break;

			case TagID.TAG_Int_Array:
			f += (value.intArrayValue.length * int.sizeof);
			break;

			case TagID.TAG_List:
			foreach (node ; value.listValue) {
				f += node.memoryFootprint;
			}
			break;

			case TagID.TAG_Compound:
			foreach (node ; value.compoundValue.byValue()) {
				f += node.memoryFootprint;
			}
			break;

			default: break;
		}

		return f;
	}

	/// Returns the size this NBT tree would be if flattened.
	@property final uint flatLength() const
	{
		void iterate(const NBTNode node, ref uint total)
		{
			total += 3 + node.name.length;
			switch (node.tagID) {
				case TagID.TAG_Byte:
				++total; return;

				case TagID.TAG_Short:
				total += 2; return;

				case TagID.TAG_Int:
				case TagID.TAG_Float:
				total += 4; return;

				case TagID.TAG_Long:
				case TagID.TAG_Double:
				total += 8; return;

				case TagID.TAG_Byte_Array:
				total += 4 + node.value.byteArrayValue.length;
				return;

				case TagID.TAG_String:
				total += 2 + node.value.stringValue.length;
				return;

				case TagID.TAG_List:
				total += 5;
				foreach (const NBTNode sn ; node.value.listValue) {
					iterate(sn, total); // but this includes headers too...
					total -= 3; total -= sn.name.length; // ...so subtract them!
				}
				return;

				case TagID.TAG_Compound:
				++total; // for TAG_End
				foreach (const NBTNode sn ; node.value.compoundValue.byValue()) {
					iterate(sn, total);
				}
				return;

				case TagID.TAG_Int_Array:
				total += 4 + (node.value.intArrayValue.length * 4);
				return;

				default: enforce(false, "Invalid tag id %s".format(node.tagID));
			}
		}
		uint r = 0;
		iterate(this, r);
		return r;
	}

	/***
		Flattens an $(D_KEYWORD NBTNode) tree back to its canonical NBT stream form.

		Returns: $(D_KEYWORD ubyte[]) of NBT stream. This return value is unaliased and can be deallocated deterministically.
	*/
	final ubyte[] flatten(bool wrapAnonymousCompound) const
	in {
		bool _workaround = wrapAnonymousCompound; // Workaround for DMD bug; without an in{} that uses wrapAnonymousCompound, it would appear corrupted to out{} on final class method
	}
	out(result) {
		auto expectedLength = this.flatLength;
		if (wrapAnonymousCompound) expectedLength += 4;
		scope(failure) stderr.writeln("Flattened NBT was: ", result);
		assert(result.length == expectedLength, "expected %d, got %d".format(expectedLength, result.length));
	}
	body
	{
		void iterate(const(NBTNode) node, ref Appender!(ubyte[]) buf, bool payloadOnly = false)
		in {
			assert(node);
			assert(node.tagID < TagID.TAG__Last);
		}
		body
		{
			if (!payloadOnly) {
				buf ~= cast(byte) node.tagID;
				buf ~= nativeToBigEndian!ushort(cast(ushort) node.name.length)[];
				buf ~= cast(immutable(ubyte)[]) node.name;
			}
			final switch (node.tagID) {
				case TagID.TAG_Byte:
				buf ~= cast(ubyte) node.value.byteValue; break;

				case TagID.TAG_Short:
				buf ~= nativeToBigEndian!short(node.value.shortValue)[]; break;

				case TagID.TAG_Int:
				buf ~= nativeToBigEndian!int(node.value.intValue)[]; break;

				case TagID.TAG_Long:
				buf ~= nativeToBigEndian!long(node.value.longValue)[]; break;

				case TagID.TAG_Float:
				buf ~= nativeToBigEndian!float(node.value.floatValue)[]; break;

				case TagID.TAG_Double:
				buf ~= nativeToBigEndian!double(node.value.doubleValue)[]; break;

				case TagID.TAG_Byte_Array:
				buf ~= nativeToBigEndian!uint(cast(uint) node.value.byteArrayValue.length)[];
				buf ~= cast(const(ubyte)[]) node.value.byteArrayValue;
				break;

				case TagID.TAG_String:
				buf ~= nativeToBigEndian!ushort(cast(ushort) node.value.stringValue.length)[];
				buf ~= cast(const(ubyte)[]) node.value.stringValue;
				break;

				case TagID.TAG_Int_Array:
				buf ~= nativeToBigEndian!uint(cast(uint) node.value.intArrayValue.length)[];
				foreach (i ; node.value.intArrayValue) {
					buf ~= nativeToBigEndian!int(i)[];
				}
				break;

				case TagID.TAG_List:
				buf ~= cast(ubyte) node.value.listValue.subnodeTagID;
				buf ~= nativeToBigEndian!uint(cast(uint) node.value.listValue.nbtnodes.length)[];
				foreach (sn ; node.value.listValue.nbtnodes) {
					enforce(sn.tagID == node.value.listValue.subnodeTagID, "TAG_List subnode is of type %s, not %s".format(humanTagTypes[sn.tagID], humanTagTypes[node.value.listValue.subnodeTagID]));
					iterate(sn, buf, true);
				}
				break;

				case TagID.TAG_Compound:
				foreach (sn ; node.value.compoundValue.byValue()) {
					iterate(sn, buf);
				}
				buf.put(cast(ubyte) 0u);
				break;

				case TagID.TAG_End: assert(0);
				case TagID.TAG__Last: assert(0);
			}
			// done?
		}
		Appender!(ubyte[]) r;

		auto expectedLength = this.flatLength;
		if (wrapAnonymousCompound) expectedLength += 4;
		r.reserve(this.flatLength);
		if (wrapAnonymousCompound) r ~= cast(ubyte[]) x"0a 00 00";
		
		iterate(this, r);
		if (wrapAnonymousCompound) r.put(cast(ubyte) 0);

		return r.data();
	}

	/***
		Deletes and deallocates a tree of NBT objects.

		This is $(B only) to be used if you can guarantee there are no other references.
	*/
	static void destroy(ref NBTNode root)
	{
		switch (root.tagID) {
			case TagID.TAG_String:
			delete root.value.stringValue;
			break;

			case TagID.TAG_Byte_Array:
			delete root.value.byteArrayValue;
			break;

			case TagID.TAG_Int_Array:
			delete root.value.intArrayValue;
			break;

			case TagID.TAG_List:
			foreach (ref sn ; root.value.listValue.nbtnodes) {
				NBTNode.destroy(sn);
				sn = null;
			}
			delete root.listValue.nbtnodes;
			break;

			case TagID.TAG_Compound:
			foreach (ref sn ; root.value.compoundValue.byValue()) {
				NBTNode.destroy(sn);
			}
			break;

			default: break;
		}

		delete root;
		root = null;
	}

	/// Alternative constructor for TAG_List subnodes.
	private this(TagID tagID, const(ubyte)[] payload, NBTNode parent)
	{
		this.tagID = tagID;
		this.parent = parent;
		_decodePayload(payload);
	}

	/// Decodes the payload of a tag.
	private final void _decodePayload(const(ubyte)[] payload)
	{

		final switch (tagID) {
			case TagID.TAG_End:
			if (parent) parent._childPayloadSize = 0; break;

			case TagID.TAG_Byte:
			value.byteValue = cast(byte) payload[0];
			if (parent) parent._childPayloadSize = 1;
			break;

			case TagID.TAG_Short:
			value.shortValue = bigEndianDynamicToNative!short(payload[0..2]);
			if (parent) parent._childPayloadSize = 2;
			break;

			case TagID.TAG_Int:
			value.intValue = bigEndianDynamicToNative!int(payload[0..4]);
			if (parent) parent._childPayloadSize = 4;
			break;

			case TagID.TAG_Long:
			value.longValue = bigEndianDynamicToNative!long(payload[0..8]);
			if (parent) parent._childPayloadSize = 8;
			break;

			case TagID.TAG_Float:
			value.floatValue = bigEndianDynamicToNative!float(payload[0..4]);
			if (parent) parent._childPayloadSize = 4;
			break;
			
			case TagID.TAG_Double:
			value.doubleValue = bigEndianDynamicToNative!double(payload[0..8]);
			if (parent) parent._childPayloadSize = 8;
			break;
			
			case TagID.TAG_Byte_Array:
			auto len = bigEndianDynamicToNative!uint(payload[0..4]);
			if (parent) parent._childPayloadSize = len + 4;
			value.byteArrayValue = (cast(const(byte)[]) payload)[4..len+4].dup;
			break;
			
			case TagID.TAG_Int_Array:
			auto len = bigEndianDynamicToNative!uint(payload[0..4]);
			value.intArrayValue.length = 0;
			value.intArrayValue.reserve(len);
			foreach (chunk ; std.range.chunks(payload[4..(len+1)*4], 4 )) {
				value.intArrayValue ~= bigEndianDynamicToNative!uint(chunk);
			}
			if (parent) parent._childPayloadSize = (len + 1)*4;
			break;
			
			case TagID.TAG_String:
			auto len = bigEndianDynamicToNative!ushort(payload[0..2]);
			// debug stderr.writefln("Here's the payload: [%s]", payload.map!q{format("%02x", a)}.join(" "));
			value.stringValue = (cast(const(char)[]) payload[2..len+2]).idup;
			if (parent) parent._childPayloadSize = len + 2;
			break;
			
			case TagID.TAG_List:
			TagID subTagID = cast(TagID) payload[0];
			value.listValue.subnodeTagID = subTagID;
			auto count = bigEndianDynamicToNative!uint(payload[1..5]);
			auto spl = payload[5..$]; //shrinking payload
			if (parent) parent._childPayloadSize = 5;
			value.listValue.length = 0;
			value.listValue.reserve(count);
			uint myPayloadSize = 0; // queue up the compound's cumulative size to pass to the parent
			foreach (i ; 0..count) {
				//stderr.writefln("List build trudging through %d bytes", spl.length);
				value.listValue ~= new NBTNode(subTagID, spl, this);
				//stderr.writefln("_childPayloadSize: %d", _childPayloadSize);
				spl = spl[_childPayloadSize..$];
				myPayloadSize += _childPayloadSize;
			}
			if (parent) parent._childPayloadSize += myPayloadSize;
			break;

			case TagID.TAG_Compound:
			// iterate thru elements until a TAG_End is reached
			auto spl = payload;
			uint myPayloadSize = 0; // queue up the compound's cumulative size to pass to the parent
			while (cast(TagID) spl[0] != TagID.TAG_End) {
				NBTNode n = new NBTNode(spl, this);
				value.compoundValue[n.name] = n;
				// now strip off the header and payload sizes from spl
				_childPayloadSize += 3 + n.name.length;
				// debug stderr.writefln("tagid %s, name %s, CPS %d", n.tagID, n.name, _childPayloadSize);
				spl = spl[_childPayloadSize..$];
				// debug stderr.writefln("Made %s %s, %d bytes of compound payload left", n.tagID, n.name, spl.length);
				myPayloadSize += _childPayloadSize;
			}
			// debug stderr.writefln("Reached TAG_End for %s: compound payloads total %d bytes", this.name, myPayloadSize);
			if (parent) parent._childPayloadSize = ++myPayloadSize; // ++ to include the TAG_End
			break;

			case TagID.TAG__Last:
			throw new Exception("TagID.TAG__Last is not a valid NBT type");
			break;
		}
	}

	debug unittest
	{
		NBTNode node = null, subnode = null;
		alias const(ubyte)[] CU;
		CU raw = null;
		string expectedLengthMsg = "Expected length %d, but got %d instead";

		/*
			Basic numeric nodes: byte, short, int, long, float, double
		*/
		raw = cast(CU) (x"01 00 04" ~"Byte"~ x"7f");
		node = new NBTNode(raw, null);
		assert(node.tagID == TagID.TAG_Byte);
		assert(node.name == "Byte");
		assert(node.value.byteValue == 0x7f);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"02 00 05" ~"Short"~ x"1eaf");
		node = new NBTNode(raw, null);
		assert(node.tagID == TagID.TAG_Short);
		assert(node.name == "Short");
		assert(node.value.shortValue == 0x1eaf, format("%08x", node.value.shortValue));
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"03 00 03" ~"Int"~ x"061ebeef");
		node = new NBTNode(raw, null);
		assert(node.tagID == TagID.TAG_Int);
		assert(node.name == "Int");
		assert(node.value.intValue == 0x061ebeef);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"04 00 04" ~"Long"~ x"00 dead c0ffee beef");
		node = new NBTNode(raw, null);
		assert(node.tagID == TagID.TAG_Long);
		assert(node.name == "Long");
		assert(node.value.longValue == 0x00deadc0ffeebeefUL);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"05 00 05" ~"Float"~ x"40 48 f5 c3"); // 3.14, plus rounding errors
		node = new NBTNode(raw, null);
		assert(node.tagID == TagID.TAG_Float);
		assert(node.name == "Float");
		assert(approxEqual(node.value.floatValue, 3.14f));
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"06 00 06" ~"Double"~ x"3FD7EC02F2F98740");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Double);
		assert(node.name == "Double");
		assert(approxEqual(node.value.doubleValue, 0.37378));
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		/*
			Compound types: byte array, int array, string
		*/

		raw = cast(CU) (x"07 00 09" ~"ByteArray"~ x"00 00 00 02 12 34");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Byte_Array);
		assert(node.name == "ByteArray");
		assert(node.value.byteArrayValue.length == 2);
		assert(node.value.byteArrayValue[0] == 0x12);
		assert(node.value.byteArrayValue[1] == 0x34);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"08 00 06" ~"String"~ x"00 0b" ~ "UTF-8 value");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_String);
		assert(node.name == "String");
		assert(node.value.stringValue == "UTF-8 value");
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		raw = cast(CU) (x"0b 00 08" ~"IntArray"~ x"
			00 00 00 04
			01 23 32 10  02 46 64 20  03 69 96 30  04 8c c8 40
		");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Int_Array);
		assert(node.name == "IntArray");
		assert(node.value.intArrayValue.length == 4);
		foreach (i ; 0..4) {
			assert(node.value.intArrayValue[i] == 0x01233210 * (i+1));
		}
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		/*
			Now, the big ones: compound and list
		*/

		// Compound: empty
		raw = cast(CU) (x"0a 00 0d" ~"EmptyCompound"~ x"00");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name == "EmptyCompound");
		assert(node.value.compoundValue.length == 0);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		// Compound: containing one element
		raw = cast(CU) (x"0a 00 09" ~"Compound1"~ x"01 00 07" ~"Subnode"~  x"7f  00");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name == "Compound1");
		assert(node.value.compoundValue.length == 1);
		assert("Subnode" in node.value.compoundValue);
		subnode = node.value.compoundValue["Subnode"];
		assert(subnode.tagID == TagID.TAG_Byte);
		assert(subnode.name == "Subnode");
		assert(subnode.value.byteValue == 0x7f);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		// Compound: containing two elements
		raw = cast(CU) (
			x"0a 00 09" ~"Compound2"
			~ x"02 00 08" ~"Subnode1"~ x"6a 01"
			~ x"02 00 08" ~"Subnode2"~ x"6a 02"
			~ x"00"
			);
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name == "Compound2");
		assert(node.value.compoundValue.length == 2);
		foreach (i ; 1 .. 3) {
			string subnodeName = format("Subnode%d", i);
			assert(subnodeName in node.value.compoundValue);
			subnode = node.value.compoundValue[subnodeName];
			assert(subnode.tagID == TagID.TAG_Short);
			assert(subnode.name == subnodeName);
			assert(subnode.value.shortValue == 0x6a00 + i);
		}
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		// can't test flatten(false) here since the order could change

		// Compound: containing four elements of differing sizes
		raw = cast(CU) (
			x"0a 00 09" ~ "Compound4"
			~ x"01 00 01 31 ff" // byte<"1">: -1
			~ x"02 00 01 32 ff fe" // short<"2">: -2
			~ x"03 00 01 33 ff ff ff fd" // int<"3">: -3
			~ x"04 00 01 34 ff ff ff ff ff ff ff fc" // long<"4">: -4
			~ x"00"
			);
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name == "Compound4");
		assert(node.value.compoundValue.length == 4);
		foreach (i ; 1..5) {
			string ca = format("%d", i);
			assert(ca in node.value.compoundValue);
			assert(node.value.compoundValue[ca].tagID == i); // tag ids go 1,2,3,4
		}
		assert(node.value.compoundValue["1"].value.byteValue == -1);
		assert(node.value.compoundValue["2"].value.shortValue == -2);
		assert(node.value.compoundValue["3"].value.intValue == -3);
		assert(node.value.compoundValue["4"].value.longValue == -4);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));

		// Empty list
		raw = cast(CU) (x"09 00 04" ~ "List" ~ x"01 00 00 00 00");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_List);
		assert(node.name == "List");
		assert(node.value.listValue.empty);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		// List: two elements
		raw = cast(CU) (x"09 00 05" ~ "List2" ~ x"02 00 00 00 02" ~ x"12 34 ab cd");
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_List);
		assert(node.name == "List2");
		assert(node.value.listValue.length == 2, format("listValue.length == %d", node.value.listValue.length));
		foreach (i ; 0..2) {
			subnode = node.value.listValue[i];
			assert(subnode !is null);
			assert(subnode.tagID == TagID.TAG_Short);
			assert(subnode.name.empty);
		}
		assert(node.value.listValue[0].value.shortValue == 0x1234);
		assert(node.value.listValue[1].value.shortValue == -0x5433, format("shortValue[2] is %d", node.value.listValue[1].value.shortValue));
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		// Nested empty compounds
		// JSON: {"e":{}}
		raw = cast(CU) x"0a 00 00 0a 00 01 65 00 00";
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name.empty);
		assert(node.value.compoundValue.length == 1);
		assert("e" in node.value.compoundValue);
		subnode = node.value.compoundValue["e"];
		assert(subnode.tagID == TagID.TAG_Compound);
		assert(subnode.name == "e");
		assert(subnode.value.compoundValue.length == 0);
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));
		assert(node.flatten(false) == raw);

		// Nested compounds with elements
		raw = cast(CU) (x"0a 00 00"
			~ x"01 00 05" ~ "Byte1" ~ x"31"
			~ x"0a 00 06" ~ "Nested"
				~ x"01 00 0a" ~ "NestedByte" ~ x"41"
			~ x"00"
			~ x"01 00 05" ~ "Byte2" ~ x"32"
			~ x"00"
			);
		assert(isValidNBT(raw));
		node = new NBTNode(raw);
		assert(node.tagID == TagID.TAG_Compound);
		assert(node.name.empty);
		assert("Byte1" in node.value.compoundValue);
		assert("Byte2" in node.value.compoundValue);
		assert("Nested" in node.value.compoundValue);
		with (node.value.compoundValue["Byte1"]) {
			assert(tagID == TagID.TAG_Byte);
			assert(name == "Byte1");
			assert(value.byteValue == 0x31);
		}
		with (node.value.compoundValue["Byte2"]) {
			assert(tagID == TagID.TAG_Byte);
			assert(name == "Byte2");
			assert(value.byteValue == 0x32);
		}
		with (node.value.compoundValue["Nested"]) {
			assert(tagID == TagID.TAG_Compound);
			assert(name == "Nested");
			assert("NestedByte" in value.compoundValue);
			with (value.compoundValue["NestedByte"]) {
				assert(tagID == TagID.TAG_Byte);
				assert(name == "NestedByte");
				assert(value.byteValue == 0x41);
			}
		}
		assert(node.flatLength == raw.length, expectedLengthMsg.format(raw.length, node.flatLength));

		// I guess that by the time it came to write the next few unit tests, NBTNode was already working so i didn't bother?

		// List in compound

		// Compound in list

		// List in list

		// Ensure a List won't get made from two nodes of different types
		raw = cast(CU) (x"09 00 05" ~ "List1" ~ x"01 00 00 00 02" ~ x"b1 b2");
		node = new NBTNode(raw);
		with (node[0]) {
			value.shortValue = 0x5001;
			tagID = TagID.TAG_Short;
		}

		assertThrown(node.flatten(false));

		// Compiling

		node = new NBTNode;
		node.tagID = TagID.TAG_Compound;

		subnode = new NBTNode;
		subnode.stringValue = "Value";

		node["Key"] = subnode;
		raw = node.flatten(false);
		{
			scope(failure) {
				stderr.writefln("Flattened node was actually %s", raw);
				stderr.writefln("Compound keys: %s", node.compoundValue.keys);
			}
			assert(raw == cast(CU) (x"0a 00 00 08 00 03" ~ "Key" ~ x"00 05" ~ "Value" ~ x"00"));
		}	
	}
}

/// Returns $(D_PARAM true) iff the array contains a valid NBT tree.
bool isValidNBT(const(ubyte)[] stream, bool ignoreTrailingBytes = false)
{
	// you can trace how this function reads NBT by enabling debug flag dc13ValidNBT. but be careful, it's verbose.
	
	const(ubyte)[] iterate(const(ubyte)[] stream, const(TagID)* onlyPayloadOfThis = null)
	{
		TagID tagID;

		// cp*: check payloads. return array reference w/o payload if successful, null if not
		const(ubyte)[] cpFixedPayload(const(ubyte)[] payload, uint minSize)
		{
			if (payload.length < minSize) return null;
			debug(dc13ValidNBT) { stderr.writef("numeric@%d ", minSize); }
			return payload[minSize .. $];
		}
		const(ubyte)[] cpString(const(ubyte)[] payload)
		{
			// we need 2 bytes for the string length, then that many again for the string
			if (payload.length < 2) return null;
			ushort strlen = bigEndianDynamicToNative!ushort(payload[0..2]);
			if ((payload.length - 2) < strlen) return null;
			debug(dc13ValidNBT) { stderr.writef("str@%d ", strlen); }
			return payload[(2 + strlen) .. $];
		}
		const(ubyte)[] cpNumericArray(const(ubyte)[] payload, uint elementSize)
		{
			// we have at least a size, right?
			if (payload.length < 4) return null;
			uint arrLength = bigEndianDynamicToNative!uint(payload[0..4]);
			uint paylen = 4 + (arrLength * elementSize);
			if (payload.length < paylen) return null; // not enough payload left to contain this
			debug(dc13ValidNBT) { stderr.writef("arr %dx%d ", elementSize, arrLength); }
			return payload[paylen .. $];
		}
		const(ubyte)[] cpList(const(ubyte)[] payload)
		{
			if (payload.length < 5) return null; // nuh-uh.
			auto tagID = cast(TagID) payload[0];
			auto listLength = bigEndianDynamicToNative!uint(payload[1..5]);
			debug(dc13ValidNBT) { stderr.writef("list(%s x %d) [ ", tagID, listLength); }
			payload = payload[5 .. $]; // remove payload metadata
			for (; listLength; --listLength) {
				payload = iterate(payload, &tagID);
				if (!payload) return null;
			}
			debug(dc13ValidNBT) { stderr.write(" ] "); }
			return payload;
		}
		const(ubyte)[] cpCompound(const(ubyte)[] payload)
		{
			debug(dc13ValidNBT) { stderr.write(" { "); }
			do {
				if (!payload.length) return null; // that ain't good
				auto sn1TagID = cast(TagID) payload[0];
				// is it a TAG_End? that can be good news in a TAG_Compound, but checkHeader expects to *not* find this
				if (sn1TagID == TagID.TAG_End) {
					debug(dc13ValidNBT) { stderr.write(" } "); }
					return payload[1 .. $]; // compound complete
				}
				payload = iterate(payload); // iterate over the whole node
				if (!payload) return null;
			} while (true);
			assert(0);
		}

		const(ubyte)[] checkHeader(const(ubyte)[] stream, TagID* outTagID = null) {
			// validate header
			if (stream.length < 3) return null; // that's never legit
			tagID = cast(TagID) stream[0];
			if (tagID == TagID.TAG_End || tagID >= TagID.TAG__Last) return null; // not a valid tag id
			ushort tagNameLength = bigEndianDynamicToNative!ushort(stream[1 .. 3]);
			if (stream.length < (3 + tagNameLength)) return null; // not a full name here
			debug(dc13ValidNBT) { stderr.writef("<%d/%s>: ", tagNameLength, cast(const(char)[]) stream[3 .. (3 + tagNameLength)]); }

			stream = stream[(3 + tagNameLength) .. $];
			if (!stream.length) return null;
			if (outTagID) *outTagID = tagID;
			return stream;
		}
		if (!onlyPayloadOfThis) {
			stream = checkHeader(stream, &tagID);
		}
		else {
			tagID = *onlyPayloadOfThis;
		}
		if (!stream) return null;

		switch (tagID) {
			case TagID.TAG_Byte:                    return cpFixedPayload(stream, 1);
			case TagID.TAG_Short:                       return cpFixedPayload(stream, 2);
			case TagID.TAG_Int:  case TagID.TAG_Float:  return cpFixedPayload(stream, 4);
			case TagID.TAG_Long: case TagID.TAG_Double: return cpFixedPayload(stream, 8);
			case TagID.TAG_String:                      return cpString(stream);         
			case TagID.TAG_Byte_Array:              return cpNumericArray(stream, 1);
			case TagID.TAG_Int_Array:                return cpNumericArray(stream, 4);
			case TagID.TAG_List:                    return cpList(stream);           
			case TagID.TAG_Compound:                return cpCompound(stream);       
			default: return null;
		}
		assert(0);
	}

	stream = iterate(stream);
	if (!stream) return false;
	if (!ignoreTrailingBytes && stream.length) return false;
	return true;
}
