#!/usr/bin/env lua

local def = io.open(arg[1] or "types.def", "r")
local c   = io.open(arg[2] or "types.c",   "w")
local h   = io.open(arg[3] or "types.h",   "w")

local function split_ws(str)
	local t = {}
	for s in str:gmatch("([^%s]+)") do
		table.insert(t, s)
	end
	return t
end

local function emit_h(str)
	h:write(str)
end

local function emit_c(str)
	c:write(str)
end

local function emit(fun, code)
	emit_h(fun .. ";\n")
	emit_c(fun ..  "\n" .. code)
end

-- fn prefixes
local struct_prefix = ""
local export_prefix = ""
local local_prefix = "__attribute__((unused)) static inline "

-- head

local disclaimer = [[
/*
	This file was automatically generated by Protogen.
	DO NOT EDIT it manually. Instead, edit types.def and re-run protogen.
*/

]]

emit_h(disclaimer)
emit_h([[
#ifndef _PROTOGEN_TYPES_H_
#define _PROTOGEN_TYPES_H_

#ifdef USE_DRAGONNET
#include <dragonnet/peer.h>
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef char *String;

typedef struct {
	uint64_t siz;
	unsigned char *data;
} ]] .. struct_prefix .. [[Blob;

]]
)

emit_c(disclaimer)
emit_c([[
#ifdef USE_DRAGONNET
#include <dragonnet/send.h>
#include <dragonnet/recv.h>
#endif

#include <endian.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define htobe8(x) (x)
#define be8toh(x) (x)

#include "types.h"

]] .. local_prefix ..  [[void raw_write(Blob *buffer, const void *data, size_t len)
{
	if (len == 0) return;
	buffer->data = realloc(buffer->data, len + buffer->siz);
	memcpy(&buffer->data[buffer->siz], data, len);
	buffer->siz += len;
}

]] .. local_prefix ..  [[bool raw_read(Blob *buffer, void *data, size_t len)
{
	if (len == 0)
		return true;

	if (buffer->siz < len) {
		fprintf(stderr, "[warning] buffer exhausted (requested bytes: %zu, remaining bytes: %" PRIu64 ")\n", len, buffer->siz);
		return false;
	}

	memcpy(data, buffer->data, len);
	buffer->data += len;
	buffer->siz -= len;
	return true;
}

]]
)

-- existing types
local existing_types = {}
local has_deallocator = {}

-- vector components

local base_vector_components = {"x", "y", "z", "w"}
local vector_components = {}

for i = 2, 4 do
	local components = {}

	for j = 1, i do
		table.insert(components, base_vector_components[j])
	end

	vector_components[i] = components
end

-- numeric types

local numeric_types = {}

local function emit_vector(type, l)
	local name = "v" .. l .. type
	local box = "aabb" .. l .. type

	existing_types[name] = true
	has_deallocator[name] = false

	existing_types[box] = true
	has_deallocator[box] = false

	local typedef, equals, add, sub, clamp, cmp, scale, mix, write, read, send, recv =
	           "",     "",  "",  "",    "",  "",    "",  "",    "",   "",   "",   ""

	for i, c in ipairs(vector_components[l]) do
		local last = i == l

		typedef = typedef
			.. c ..
			(last
				and ";\n"
				or ", "
			)

		equals = equals
			.. "a." .. c .. " == "
			.. "b." .. c ..
			(last
				and ";\n"
				or " && "
			)

		add = add
			.. "a." .. c .. " + "
			.. "b." .. c ..
			(last
				and "};\n"
				or ", "
			)

		sub = sub
			.. "a." .. c .. " - "
			.. "b." .. c ..
			(last
				and "};\n"
				or ", "
			)

		clamp = clamp
			.. type .. "_clamp("
			.. "val." .. c .. ", "
			.. "min." .. c .. ", "
			.. "max." .. c .. ")" ..
			(last
				and "};\n"
				or ", "
			)

		cmp = cmp
			.. "\tif ((i = " .. type .. "_cmp("
			.. "&((const " .. name .. " *) a)->" .. c .. ", "
			.. "&((const " .. name .. " *) b)->" .. c .. ")) != 0)"
			.. "\n\t\treturn i;\n"

		scale = scale
			.. "v." .. c .. " * s" ..
			(last
				and "};\n"
				or ", "
			)

		mix = mix
			.. type .. "_mix("
			.. "a." .. c .. ", "
			.. "b." .. c .. ", "
			.. "f" .. ")" ..
			(last
				and "};\n"
				or ", "
			)

		write = write
			.. "\t" .. type .. "_write(buffer, &val->" .. c .. ");\n"

		read = read
			.. "\tif (!" .. type .. "_read(buffer, &val->" .. c .. "))\n\t\treturn false;\n"

		send = send
			.. "\tif (!" .. type .. "_send(peer, " .. (last and "submit" or "false") .. ", &val->" .. c .. "))\n\t\treturn false;\n"

		recv = recv
			.. "\tif (!" .. type .. "_recv(peer, &val->" .. c .. "))\n\t\treturn false;\n"
	end

	emit_h("typedef struct {\n\t" .. type .. " " .. typedef ..  "} " .. struct_prefix .. name .. ";\n")

	emit(export_prefix .. "bool " .. name .. "_equals(" .. name .. " a, " .. name .. " b)", "{\n\treturn " .. equals .. "}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_add(" .. name .. " a, " .. name .. " b)", "{\n\treturn (" .. name .. ") {" .. add .. "}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_sub(" .. name .. " a, " .. name .. " b)", "{\n\treturn (" .. name .. ") {" .. sub .. "}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_clamp(" .. name .. " val, " .. name .. " min, " .. name .. " max)", "{\n\treturn (" .. name .. ") {" .. clamp .. "}\n\n")
	emit(export_prefix .. "int " .. name .. "_cmp(const void *a, const void *b)", "{\n\tint i;\n" .. cmp .. "\treturn 0;\n}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_scale(" .. name .. " v, " .. type .. " s)", "{\n\treturn (" .. name .. ") {" .. scale .. "}\n\n")

	if type:sub(1, 1) == "f" then
		emit(export_prefix .. name .. " " .. name .. "_mix(" .. name .. " a, " .. name .. " b, " .. type .. " f)", "{\n\treturn (" .. name .. ") {" .. mix .. "}\n\n")
	end

	emit(export_prefix .. "void " .. name .. "_write(Blob *buffer, " .. name .. " *val)", "{\n" .. write .. "}\n\n")
	emit(export_prefix .. "bool " .. name .. "_read(Blob *buffer, " .. name .. " *val)", "{\n" .. read .. "\treturn true;\n}\n\n")

	emit_c("#ifdef USE_DRAGONNET\n")
	emit_c(local_prefix .. "bool " .. name .. "_send(DragonnetPeer *peer, bool submit, " .. name .. " *val)\n{\n" .. send .. "\treturn true;\n}\n\n")
	emit_c(local_prefix .. "bool " .. name .. "_recv(DragonnetPeer *peer, " .. name .. " *val)\n{\n" .. recv .. "\treturn true;\n}\n")
	emit_c("#endif\n\n")

	emit_h("\n")

	emit_h("typedef struct {\n\t" .. name .. " min, max;\n} " .. struct_prefix .. box .. ";\n")

	emit(export_prefix .. "void " .. box .. "_write(Blob *buffer, " .. box .. " *val)", "{\n\t" .. name .. "_write(buffer, &val->min);\n\t" .. name .. "_write(buffer, &val->max);\n}\n\n")
	emit(export_prefix .. "bool " .. box .. "_read(Blob *buffer, " .. box .. " *val)", "{\n\tif (!" .. name .. "_read(buffer, &val->min))\n\t\treturn false;\n\tif (!" .. name .. "_read(buffer, &val->max))\n\t\treturn false;\n\treturn true;\n}\n\n")

	emit_c("#ifdef USE_DRAGONNET\n")
	emit_c(local_prefix .. "bool " .. box .. "_send(DragonnetPeer *peer, bool submit, " .. box .. " *val)\n{\n\tif (!" .. name .. "_send(peer, false, &val->min))\n\t\treturn false;\n\tif (!" .. name .. "_send(peer, submit, &val->max))\n\t\treturn false;\n\treturn true;\n}\n\n")
	emit_c(local_prefix .. "bool " .. box .. "_recv(DragonnetPeer *peer, " .. box .. " *val)\n{\n\tif (!" .. name .. "_recv(peer, &val->min))\n\t\treturn false;\n\t if (!" .. name .. "_recv(peer, &val->max))\n\t\treturn false;\n\treturn true;\n}\n")
	emit_c("#endif\n\n")

	emit_h("\n")
end

local function emit_numeric(class, bits, alias)
	local name = class .. bits
	table.insert(numeric_types, name)

	existing_types[name] = true
	has_deallocator[name] = false

	emit_h("typedef " .. alias .. " " .. name .. ";\n")

	emit(export_prefix .. name .. " " .. name .. "_min(" .. name .. " a, " .. name .. " b)", "{\n\treturn a < b ? a : b;\n}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_max(" .. name .. " a, " .. name .. " b)", "{\n\treturn a > b ? a : b;\n}\n\n")
	emit(export_prefix .. name .. " " .. name .. "_clamp(" .. name .. " val, " .. name .. " min, " .. name .. " max)", "{\n\treturn val < min ? min : val > max ? max : val;\n}\n\n")
	emit(export_prefix .. "int " .. name .. "_cmp(const void *a, const void *b)", "{\n\treturn\n\t\t*(const " .. name .. " *) a < *(const " .. name .. " *) b ? -1 :\n\t\t*(const " .. name .. " *) a > *(const " .. name .. " *) b ? +1 :\n\t\t0;\n}\n\n")

	if class == "f" then
		emit(export_prefix .. name .. " " .. name .. "_mix(" .. name .. " a, " .. name .. " b, " .. name .. " f)", "{\n\treturn (1.0 - f) * a + b * f;\n}\n\n")
	end

	emit(export_prefix .. "void " .. name .. "_write(Blob *buffer, " .. name .. " *val)", "{\n" .. (class == "u"
		and "\t" .. name .. " be = htobe" .. bits .. "(*val);\n\traw_write(buffer, &be, sizeof be);\n"
		or  "\tu" .. bits .. "_write(buffer, (u" .. bits .. " *) val);\n"
	) .. "}\n\n")
	emit(export_prefix .. "bool " .. name .. "_read(Blob *buffer, " .. name .. " *val)", "{\n" .. (class == "u"
		and "\t" .. name .. " be;\n\tif (!raw_read(buffer, &be, sizeof be))\n\t\treturn false;\n\t*val = be" .. bits .. "toh(be);\n\treturn true;\n"
		or  "\treturn u" .. bits .. "_read(buffer, (u" .. bits .. " *) val);\n"
	) .. "}\n\n")

	emit_c("#ifdef USE_DRAGONNET\n")
	emit_c(local_prefix .. "bool " .. name .. "_send(DragonnetPeer *peer, bool submit, " .. name .. " *val)\n{\n" .. (class == "u"
		and "\t" .. name .. " be = htobe" .. bits .. "(*val);\n\treturn dragonnet_send_raw(peer, submit, &be, sizeof be);\n"
		or  "\treturn u" .. bits .. "_send(peer, submit, (u" .. bits .. " *) val);\n"
	) .. "}\n\n")
	emit_c(local_prefix .. "bool " .. name .. "_recv(DragonnetPeer *peer, " .. name .. " *val)\n{\n" .. (class == "u"
		and "\t" .. name .. " be;\n\tif (!dragonnet_recv_raw(peer, &be, sizeof be))\n\t\treturn false;\n\t*val = be" .. bits .. "toh(be);\n\treturn true;\n"
		or  "\treturn u" .. bits .. "_recv(peer, (u" .. bits .. " *) val);\n"
	) .. "}\n")
	emit_c("#endif\n\n")

	emit_h("\n")

	for i = 2, 4 do
		emit_vector(name, i)
	end
end

for i = 0, 3 do
	local bytes = math.floor(2 ^ i)
	local bits = 8 * bytes

	emit_numeric("u", bits, "uint" .. bits .. "_t")
	emit_numeric("s", bits,  "int" .. bits .. "_t")

	if i >= 2 then
		emit_numeric("f", bits, ({"float", "double"})[i - 1])
	end
end

local converters = {}

for l = 2, 4 do
	converters[l] = ""

	for i, c in ipairs(vector_components[l]) do
		converters[l] = converters[l]
			.. "v." .. c ..
			((i == l)
				and "};\n"
				or ", "
			)
	end
end

for _, from in ipairs(numeric_types) do
	for _, to in ipairs(numeric_types) do
		if from ~= to then
			for i = 2, 4 do
				local v_from = "v" .. i .. from
				local v_to   = "v" .. i .. to

				emit(export_prefix .. v_to .. " " .. v_from .. "_to_" .. to  .. "(" .. v_from .. " v)", "{\n\treturn (" .. v_to .. ") {" .. converters[i] .. "}\n\n")
			end
		end
	end
end

emit_h("\n")

-- string

existing_types.String = true
has_deallocator.String = true

emit(
export_prefix .. "void String_free(String *val)", [[
{
	if (*val)
		free(*val);
}

]]
)

emit(
export_prefix .. "void String_write(Blob *buffer, String *val)", [[
{
	*val ? raw_write(buffer, *val, strlen(*val) + 1) : raw_write(buffer, "", 1);
}

]]
)

emit(
export_prefix .. "bool String_read(Blob *buffer, String *val)", [[
{
	String v = malloc(1 + (1 << 16));

	char c;
	for (u16 i = 0;; i++) {
		if (!raw_read(buffer, &c, 1)) {
			free(v);
			return false;
		}

		v[i] = c;
		if (c == '\0')
			break;
	}

	*val = realloc(v, strlen(v) + 1);

	return true;
}

]]
)

emit_c(
[[
#ifdef USE_DRAGONNET
]] .. local_prefix .. [[bool String_send(DragonnetPeer *peer, bool submit, String *val)
{
	return *val ? dragonnet_send_raw(peer, submit, *val, strlen(*val) + 1) : dragonnet_send_raw(peer, submit, "", 1);
}

]] .. local_prefix .. [[bool String_recv(DragonnetPeer *peer, String *val)
{
	String v = malloc(1 + (1 << 16));

	char c;
	for (u16 i = 0;; i++) {
		if (!dragonnet_recv_raw(peer, &c, 1)) {
			free(v);
			return false;
		}

		v[i] = c;
		if (c == '\0')
			break;
	}

	*val = realloc(v, strlen(v) + 1);

	return true;
}
#endif

]]
)

emit_h("\n")

-- blob

existing_types.Blob = true
has_deallocator.Blob = true

emit(
export_prefix .. "void Blob_compress(Blob *buffer, Blob *val)", [[
{
	buffer->siz = 8 + 2 + val->siz;
	buffer->data = malloc(buffer->siz);

	*(u64 *) buffer->data = val->siz;

	z_stream s;
	s.zalloc = Z_NULL;
	s.zfree = Z_NULL;
	s.opaque = Z_NULL;

	s.avail_in = val->siz;
	s.next_in = (Bytef *) val->data;
	s.avail_out = buffer->siz - 8 + 1;
	s.next_out = (Bytef *) buffer->data + 8;

	deflateInit(&s, Z_BEST_COMPRESSION);
	deflate(&s, Z_FINISH);
	deflateEnd(&s);

	buffer->siz = s.total_out + 8;
}

]]
)

emit(
export_prefix .. "void Blob_decompress(Blob *buffer, Blob *val)", [[
{
	buffer->siz = *(u64 *) val->data;
	buffer->data = malloc(buffer->siz);

	z_stream s;
	s.zalloc = Z_NULL;
	s.zfree = Z_NULL;
	s.opaque = Z_NULL;

	s.avail_in = val->siz - 8;
	s.next_in = val->data + 8;
	s.avail_out = buffer->siz;
	s.next_out = (Bytef *) buffer->data;

	inflateInit(&s);
	inflate(&s, Z_NO_FLUSH);
	inflateEnd(&s);

	buffer->siz = s.total_out;
}

]]
)

emit(
export_prefix .. "void Blob_shrink(Blob *val)", [[
{
	val->data = realloc(val->data, val->siz);
}

]]
)

emit(
export_prefix .. "void Blob_free(Blob *val)", [[
{
	if (val->data)
		free(val->data);
}

]]
)

emit(
export_prefix .. "void Blob_write(Blob *buffer, Blob *val)", [[
{
	u64_write(buffer, &val->siz);
	raw_write(buffer, val->data, val->siz);
}

]]
)

emit(
export_prefix .. "bool Blob_read(Blob *buffer, Blob *val)", [[
{
	if (!u64_read(buffer, &val->siz))
		return false;

	if (!raw_read(buffer, val->data = malloc(val->siz), val->siz)) {
		free(val->data);
		val->data = NULL;
		return false;
	}

	return true;
}

]]
)

emit_c(
[[
#ifdef USE_DRAGONNET
]] .. local_prefix .. [[bool Blob_send(DragonnetPeer *peer, bool submit, Blob *val)
{
	if (!u64_send(peer, false, &val->siz))
		return false;
	return dragonnet_send_raw(peer, submit, val->data, val->siz);
}

]] .. local_prefix .. [[bool Blob_recv(DragonnetPeer *peer, Blob *val)
{
	if (!u64_recv(peer, &val->siz))
		return false;

	if (!dragonnet_recv_raw(peer, val->data = malloc(val->siz), val->siz)) {
		free(val->data);
		val->data = NULL;
		return false;
	}

	return true;
}
#endif

]]
)

emit_h("\n")


emit_c(
[[
]] .. local_prefix .. [[void raw_write_compressed(Blob *buffer, void *val, void (*val_write)(Blob *, void *))
{
	Blob compressed, raw = {0};
	val_write(&raw, val);
	Blob_compress(&compressed, &raw);
	Blob_write(buffer, &compressed);

	Blob_free(&compressed);
	Blob_free(&raw);
}

]] .. local_prefix .. [[bool raw_read_compressed(Blob *buffer, void *val, bool (*val_read)(Blob *, void *))
{
	Blob compressed, raw = {0};
	bool success = Blob_read(buffer, &compressed);

	if (success) {
		Blob_decompress(&raw, &compressed);
		Blob raw_buffer = raw;
		success = success && val_read(&raw_buffer, val);
	}

	Blob_free(&compressed);
	Blob_free(&raw);

	return success;
}

#ifdef USE_DRAGONNET
]] .. local_prefix .. [[bool raw_send_compressed(DragonnetPeer *peer, bool submit, void *val, void (*val_write)(Blob *, void *))
{
	Blob compressed, raw = {0};
	val_write(&raw, val);
	Blob_compress(&compressed, &raw);
	bool success = Blob_send(peer, submit, &compressed);

	Blob_free(&compressed);
	Blob_free(&raw);

	return success;
}

]] .. local_prefix .. [[bool raw_recv_compressed(DragonnetPeer *peer, void *val, bool (*val_read)(Blob *, void *))
{
	Blob compressed, raw = {0};
	bool success = Blob_recv(peer, &compressed);

	if (success) {
		Blob_decompress(&raw, &compressed);
		Blob raw_buffer = raw;
		success = success && val_read(&raw_buffer, val);
	}

	Blob_free(&compressed);
	Blob_free(&raw);

	return success;
}
#endif

]]
)

local custom_types = {}
local current_type

local function consume_name(name)
	if current_type then
		table.insert(custom_types, current_type)
	end

	if name == "" then
		current_type = nil
	else
		current_type = {components = {}, component_names = {}}

		current_type.flags = split_ws(name)
		current_type.name = table.remove(current_type.flags, #current_type.flags)

		if existing_types[current_type.name] then
			error("redeclaration of type " .. current_type.name)
		end

		existing_types[current_type.name] = true
		has_deallocator[current_type.name] = false
	end
end

local function consume_comp(comp)
	if not current_type then
		error("component without a type: " .. comp)
	end

	local component = {}

	component.flags = split_ws(comp)
	component.name = table.remove(component.flags, #component.flags)
	component.type = table.remove(component.flags, #component.flags)

	component.full_name = current_type.name .. "." .. component.name

	local base_type = ""
	local met_brace = false
	local brace_level = 0

	for i = 1, #component.type do
		local c = component.type:sub(i, i)
		local append = false

		if c == "[" then
			if not met_brace then
				component.array = {}
			end

			met_brace = true
			brace_level = brace_level + 1

			if brace_level == 1 then
				table.insert(component.array, "")
			else
				append = true
			end
		elseif c == "]" then
			brace_level = brace_level - 1

			if brace_level < 0 then
				error("missing [ in " .. component.full_name)
			elseif brace_level > 0 then
				append = true
			end
		elseif not met_brace then
			base_type = base_type .. c
		elseif brace_level == 1 then
			append = true
		elseif brace_level == 0 then
			error("invalid character " .. c .. " outside of braces in " .. component.full_name)
		end

		if append then
			component.array[#component.array] = component.array[#component.array] .. c
		end
	end

	component.type = base_type

	if brace_level > 0 then
		error("missing ] in " .. component.full_name)
	end

	if not existing_types[component.type] then
		error("type " .. component.type .. " of " .. component.full_name .. " does not exist ")
	end

	has_deallocator[current_type.name] = has_deallocator[current_type.name] or has_deallocator[component.type]

	if current_type.component_names[component.name] then
		error("component " .. component.full_name .. " redeclared")
	end

	current_type.component_names[component.name] = true

	table.insert(current_type.components, component)
end

if def then
	for l in def:lines() do
		local f = l:sub(1, 1)

		if f == "\t" then
			consume_comp(l:sub(2, #l))
		elseif f == "#" then
			emit_h(l .. "\n\n")
		elseif f ~= ";" then
			consume_name(l)
		end
	end
end

consume_name("")

local dragonnet_types_h = ""
local dragonnet_types_c = ""

for _, t in ipairs(custom_types) do
	local pkt

	for _, f in pairs(t.flags) do
		if f == "pkt" then
			pkt = true
		else
			error("invalid flag " .. f .. " for " .. t.name)
		end
	end

	local typedef, free, write, read, send, recv =
	           "",   "",    "",   "",   "",   ""

	for ic, c in ipairs(t.components) do
		local type = c.type
		local type_end = ""

		if c.array then
			local indices = {}

			for _, a in ipairs(c.array) do
				table.insert(indices, 1, a)
			end

			for _, a in ipairs(indices) do
				if a == "" then
					type = "struct { size_t siz; " .. type .. " (*ptr)" .. type_end .. "; }"
					type_end = ""
				else
					type_end = "[" .. a .. "]" .. type_end
				end
			end
		end

		typedef = typedef
			.. "\t" .. type .. " " .. c.name .. type_end .. ";\n"

		local compressed = false

		for _, f in pairs(c.flags) do
			if f == "compressed" then
				compressed = true
			else
				error("invalid flag " .. f .. " for " .. c.full_name)
			end
		end

		local indent = {
			free = "\t",
			write = "\t",
			read = "\t",
			send = "\t",
			recv = "\t",
		}
		local loop = {
			free = "",
			write = "",
			read = "",
			send = "",
			recv = ""
		}
		local loop_end = {
			free = "",
			write = "",
			read = "",
			send = "",
			recv = ""
		}
		local index = ""
		local array_submit = ""

		if c.array then
			for ia, a in ipairs(c.array) do
				local it = "i" .. ia
				local siz = a

				if a == "" then
					local var = "val->" .. c.name .. index
					local ptr = var .. ".ptr"
					siz = var .. ".siz"

					loop.free = loop.free .. indent.free .. "if (" .. ptr .. ") {\n"
					loop_end.free = indent.free .. "}\n" .. loop_end.free
					indent.free = indent.free .. "\t"
					loop_end.free = indent.free .. "free(" .. ptr .. ");\n" .. loop_end.free

					loop.write = loop.write .. indent.write .. "u64_write(buffer, &" .. siz .. ");\n"

					loop.send = loop.send .. indent.send .. "if (!u64_send(peer, &" .. siz .. ", false))\n"
						.. indent.send .. "\treturn false;\n"

					loop.read = loop.read .. indent.read .. "if (!u64_read(buffer, &" .. siz .. "))\n"
						.. indent.read .. "\treturn false;\n"
						.. indent.read .. ptr .. " = calloc(" .. siz .. ", sizeof *" .. ptr .. ");\n"

					loop.recv = loop.recv .. indent.recv .. "if (!u64_recv(peer, &" .. siz .. "))\n"
						.. indent.recv .. "\treturn false;\n"
						.. indent.recv .. ptr .. " = calloc(" .. siz .. ", sizeof *" .. ptr .. ");\n"

					index = index .. ".ptr"
				end

				for f in pairs(loop) do
					loop[f] = loop[f] .. indent[f] .. "for (size_t " .. it .. " = 0; " .. it .. " < " .. siz .. "; " .. it .. "++) {\n"
					loop_end[f] = indent[f] .. "}\n" .. loop_end[f]
					indent[f] = indent[f] .. "\t"
				end

				index = index .. "[" .. it .. "]"
				array_submit = array_submit .. " && " .. it .. " == " .. siz .. " - 1"
			end
		end

		local addr = "&val->" .. c.name .. index

		if has_deallocator[c.type] then
			free = free
				.. loop.free .. indent.free .. c.type .. "_free(" .. addr .. ");\n" .. loop_end.free
		end

		write = write
			.. loop.write .. indent.write .. (compressed
				and "raw_write_compressed(buffer, " .. addr .. ", (void *) &" .. c.type .. "_write);\n"
				or      c.type .. "_write(buffer, " .. addr .. ");\n"
			) .. loop_end.write

		read = read
			.. loop.read .. indent.read .. "if (!" .. (compressed
				and "raw_read_compressed(buffer, " .. addr .. ", (void *) &" .. c.type .. "_read)"
				or      c.type .. "_read(buffer, " .. addr .. ")"
			) .. ")\n" .. indent.read .. "\treturn false;\n" .. loop_end.read

		local submit = ic == #t.components and "submit" .. array_submit or "false"
		send = send
			.. loop.send .. indent.send .. "if (!" .. (compressed
				and "raw_send_compressed(peer, " .. submit .. ", " .. addr .. ", (void *) &" .. c.type .. "_write)"
				or      c.type .. "_send(peer, " .. submit .. ", " .. addr .. ")"
			) .. ")\n" .. indent.send .. "\treturn false;\n" .. loop_end.send

		recv = recv
			.. loop.recv .. indent.recv .. "if (!" .. (compressed
				and "raw_recv_compressed(peer, " .. addr .. ", (void *) &" .. c.type .. "_read)"
				or      c.type .. "_recv(peer, " .. addr .. ")"
			) .. ")\n" .. indent.recv .. "\treturn false;\n" .. loop_end.recv
	end

	emit_h("typedef struct {\n" .. typedef .. "} " .. struct_prefix .. t.name .. ";\n")

	if has_deallocator[t.name] then
		emit(export_prefix .. "void " .. t.name .. "_free(" .. t.name .. " *val)", "{\n" .. free .. "}\n\n")
	end

	emit(export_prefix .. "void " .. t.name .. "_write(Blob *buffer, " .. t.name .. " *val)", "{\n" .. write .. "}\n\n")
	emit(export_prefix .. "bool " .. t.name .. "_read(Blob *buffer, " .. t.name .. " *val)", "{\n" .. read .. "\treturn true;\n}\n\n")

	if pkt then
		emit_h("#ifdef USE_DRAGONNET\n")
	end

	emit_c("#ifdef USE_DRAGONNET\n")

	emit_c(local_prefix .. "bool " .. t.name .. "_send(DragonnetPeer *peer, bool submit, " .. t.name .. " *val)\n{\n" .. send .. "\treturn true;\n}\n\n")
	emit_c(local_prefix .. "bool " .. t.name .. "_recv(DragonnetPeer *peer, " .. t.name .. " *val)\n{\n" .. recv .. "\treturn true;\n}\n")

	if pkt then
		emit_c("\n")
		emit_c("static DragonnetTypeId " .. t.name .. "_type_id = DRAGONNET_TYPE_" .. t.name .. ";\n")

		emit("bool dragonnet_peer_send_" .. t.name .. "(DragonnetPeer *peer, " .. t.name .. " *val)", "{\n\tpthread_mutex_lock(&peer->mtx);\n\tif (!u16_send(peer, false, &" .. t.name .. "_type_id))\n\t\treturn false;\n\tif (!" .. t.name .. "_send(peer, true, val))\n\t\treturn false;\n\treturn true;\n}\n")
		emit_h("#endif\n")

		dragonnet_types_h = dragonnet_types_h
			.. "\tDRAGONNET_TYPE_" .. t.name .. ",\n"

		dragonnet_types_c = dragonnet_types_c
			.. "\t{\n\t\t.siz = sizeof(" .. t.name .. "),\n\t\t.deserialize = (void *) &" .. t.name .. "_recv,\n\t\t.free = " .. (has_deallocator[t.name] and "(void *) &" .. t.name .. "_free" or "NULL") .. ",\n\t},\n"
	end

	emit_c("#endif\n\n")

	emit_h("\n")
end

emit_h("#ifdef USE_DRAGONNET\n")
emit_h("typedef enum {\n" .. dragonnet_types_h .. "\tDRAGONNET_NUM_TYPES\n} DragonnetTypeNum;\n")
emit_h("#endif\n\n")

emit_c("#ifdef USE_DRAGONNET\n")
emit_c("DragonnetTypeId dragonnet_num_types = DRAGONNET_NUM_TYPES;\nDragonnetType dragonnet_types[] = {\n" .. dragonnet_types_c .. "};\n")
emit_c("#endif\n")

emit_h("#endif\n")

h:close()
c:close()
def:close()
