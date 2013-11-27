#!/usr/bin/python
from __future__ import print_function
import os, sys, json
from math import log
from datetime import datetime
import re

def quoteAndEscape(s):
	r"""Enquote s, escaping quote marks and backslashes. As a convenience, \n and \r are also stripped."""
	return "\"%s\"" % s.replace("\n",'').replace("\r",'').replace("\\", "\\\\").replace("\"", "\\\"")

# print(sys.argv)

fpoutname = sys.argv[1]
if fpoutname == '-':
	print("Printing to stdout", file=sys.stderr)
	fpout = sys.stdout;
else:
	print("Saving to %s"%fpoutname, file=sys.stderr)
	fpout = open(fpoutname, 'wt')

if len(sys.argv) > 2:
	jpath = sys.argv[2]
else:
	jpath = "data.json"


jroot = json.load(open(jpath, "rt"))

Template = u"""/*

Disasterclass: data.d || Minecraft block and item data
Automatically generated on %(Date)s; DO NOT EDIT

Written in the D programming language.

This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

*/
module disasterclass.data;

import disasterclass.support;

import std.exception : assumeUnique;
import std.string : format;

public {
	string blockOrItemName(BlockID block, BlockData data = 0)
	in {
		assert(data <= 15);
	}
	body
	{
		// note that this code uses the assumption that blocks < 256, items >= 256.
		// it won't be this way forever.

		if (block <= 255) {
			auto firstMatchB = block in Blocks;
			if (firstMatchB is null || firstMatchB.name is null) return "[unknown block %%d]".format(block);

			if (firstMatchB.subData is null) return firstMatchB.name;
			return firstMatchB.subData.subName[data];
		}	

		else {
			auto firstMatchI = block in Items;
			if (firstMatchI is null || firstMatchI.name is null) return "[unknown item %%d]".format(block);

			// todo: use damage for subitem
			return firstMatchI.name;
		}
	}
}

package:

struct Block
{
	string name;
	BlockVariantNames* subData;
	uint flags;
}

struct BlockVariantNames
{
	string[16] subName;
}

struct Item
{
	string name;
	uint flags;
}

static __gshared immutable  Block[BlockID]     Blocks;
static __gshared immutable   Item[BlockID]     Items;

//SubitemData
//%(SubitemDeclarations)s
//;

enum BlockType : BlockID
{
%(BlockTypesEnum)s
}

enum ItemType : ItemID
{
%(ItemTypesEnum)s
}

%(FlagsEnum)s

shared static this()
{
	Block[BlockID] b;
%(BlockDataDeclarations)s
	b.rehash();
	Blocks = b.assumeUnique();

	Item [BlockID] i;
%(ItemDataDeclarations)s
	i.rehash();
	Items = i.assumeUnique();
}

"""

class Flags:
	NotValidId           = 0x80000000
	Block                = 0x40000000
	UsesDataField        = 0x20000000
	TileEntity           = 0x10000000
	BlockLightLevel_M    = 0x0f000000
	Transparent          = 0x00400000
	Opaque               = 0x00200000
	Solid                = 0x00100000
	SensitiveToPlacement = 0x00040000
	WallSupport          = 0x00020000
	FloorSupport         = 0x00010000
	BlockItemIdsDiffer   = 0x00008000
	UsesDamage           = 0x00002000
	OnlyCreativeLegit    = 0x00001000
	OnlySilkTouchLegit   = 0x00000800
	Tool                 = 0x00000010
	Armour               = 0x00000008
	LogMaxStack_M        = 0x00000007

	BlockLightLevel_S    = 24
	LogMaxStack_S        = 0

	@classmethod
	def asDCode(cls):
		flagNames = [x for x in dir(cls) if not x.endswith('__') and type(cls.__dict__[x]) == int]
		maxKeyLength = max(len(x) for x in flagNames)

		flags = [(x, cls.__dict__[x]) for x in flagNames if x[-2:] != "_S"]
		flags.sort(cmp = lambda a, b: cmp(b[1], a[1]))
		flags += [(x, cls.__dict__[x]) for x in flagNames if x[-2:] == "_S"]

		s = ",\n".join( "\t%s = 0x%s" % (x[0].ljust(maxKeyLength), hex(x[1])[2:].zfill(8)) for x in flags )
		return "enum Flags {\n%s\n}" % s       

def makeEnumName(s):
	match = rMusicDisc.match(s)
	if match:
		# is a music disc
		return rMusicDisc.sub("Music_Disc_\\1", s)
	else:
		# do standard substitutions
		return s.replace("\x20", "_").replace("'", '').replace("(", '').replace(")", '') # assuming no other problems		

Fields = {}
Fields['Date'] = datetime.now().isoformat()
Fields['SubitemDeclarations'] = " <not implemented>"
Fields['ItemDataDeclarations'] = "\t// not implemented"

Fields['FlagsEnum'] = Flags.asDCode()

idd = []
maxBlockIdLen = max(len(str(x['Id'])) for x in jroot['Blocks'])

rMusicDisc = re.compile(r"^(.*) Disc$")

for blk in jroot['Blocks']:
	blk['_IdPadded'] = str(blk["Id"]).rjust(maxBlockIdLen, "\x20")
	blk['_NameQuoted'] = quoteAndEscape(blk['Name'])

	blk['_EnumName'] = makeEnumName(blk['Name'])

	flags = 0
	logstack = int(log(blk['MaxStack'], 2))
	assert(1<<logstack == blk['MaxStack'])
	assert(logstack <= 7)
	flags |= logstack
	if "IsArmour" in blk['Flags']:
		flags |= Flags.Armour
	if "IsTool" in blk['Flags']:
		flags |= Flags.Tool
	if "IsBlock" in blk['Flags'] or blk['Id'] <= 255:
		flags |= Flags.Block
	if "UsesDamage" in blk['Flags']:
		flags |= Flags.UsesDamage
	if "DifferentItemId" in blk['Flags']:
		flags |= Flags.BlockItemIdsDiffer
	if "SensitiveToPlacement" in blk['Flags']:
		flags |= Flags.SensitiveToPlacement
	if "Light" in blk:
		blockLight = blk['Light']
		assert(blockLight <= 15)
		assert(blockLight >= 0)
		flags |= (blockLight << Flags.BlockLightLevel_S)
	if "TileEntity" in blk['Flags']:
		flags |= Flags.TileEntity
	if "HasData" in blk['Flags']:
		flags |= Flags.UsesDataField
	if "Transparent" in blk['Flags']:
		flags |= Flags.Transparent
	if "Opaque" in blk['Flags']:
		flags |= Flags.Opaque
	if "Solid" in blk['Flags']:
		flags |= Flags.Solid

	blk['Flags'] = "%08x" % flags

	idd.append("""\tb[%(_IdPadded)s] = Block(%(_NameQuoted)s, null, 0x%(Flags)s);""" % blk)

enumNames = [(b['_EnumName'], b['Id']) for b in jroot["Blocks"]]
enumNames.sort(lambda a, b: cmp(a[1], b[1]))
maxEnumLength = max(len(x[0]) for x in enumNames)
Fields['BlockTypesEnum'] = ",\n".join("\t%s = %d" % (x[0].ljust(maxEnumLength), x[1]) for x in enumNames)
Fields['ItemTypesEnum'] = 'None = 0 // currently unsupported'

Fields['BlockDataDeclarations'] = '\n'.join(idd)

print(Template % Fields, file=fpout)



