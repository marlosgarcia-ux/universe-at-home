--!native
--!optimize 2
-- universe-at-home :: compute/Expr
--
-- One 2D signed-distance expression, evaluated four ways, to measure what the
-- evaluation strategy costs in Luau (docs/COMPUTE.md 4.1):
--
--   closure     a tree of closures, one call per node per pixel
--   ops         a flat op array (numbers in a table) run by a register machine,
--               one dispatch per node per pixel
--   opsRow      the same op array run column-at-a-time over a whole row: one
--               dispatch per node per ROW, the inner loop is pure arithmetic
--   source      Luau source text for a per-pixel function or a row kernel,
--               loaded with loadstring (server only in Roblox, LoadStringEnabled)
--               or emitted at build time as a ModuleScript
--
-- All four perform the same operations in the same order, so they return
-- bit-identical values (tests/compute.test.luau). The module also evaluates the
-- expression over a box in interval arithmetic (exact ranges for every node
-- here, because each op is monotone in each argument or handled piecewise), and
-- renders it through a quadtree classified by either intervals or a Lipschitz
-- bound (docs/COMPUTE.md 2.1 and 3.1).
--
-- Deterministic ops only: + - * / sqrt abs min max comparisons.

local MyMath = require("../MyMath")
local Pixels = require("../Pixels")

local Expr = {}

export type Node = {
	op: number,
	a: Node?,
	b: Node?,
	p1: number,
	p2: number,
	p3: number,
	p4: number,
}

local CIRCLE, BOX, MIN, MAX, SMIN, NEG, OFFSET, SHELL = 1, 2, 3, 4, 5, 6, 7, 8

local function leaf(op: number, p1: number, p2: number, p3: number, p4: number): Node
	return { op = op, p1 = p1, p2 = p2, p3 = p3, p4 = p4 }
end

local function node(op: number, a: Node, b: Node?, k: number?): Node
	return { op = op, a = a, b = b, p1 = k or 0, p2 = 0, p3 = 0, p4 = 0 }
end

function Expr.circle(cx: number, cy: number, r: number): Node
	return leaf(CIRCLE, cx, cy, r, 0)
end
-- Sharp axis-aligned box: centre (cx, cy), half extents (hx, hy).
function Expr.box(cx: number, cy: number, hx: number, hy: number): Node
	return leaf(BOX, cx, cy, hx, hy)
end
function Expr.union(a: Node, b: Node): Node
	return node(MIN, a, b)
end
function Expr.intersect(a: Node, b: Node): Node
	return node(MAX, a, b)
end
-- Polynomial smooth union (MyMath.smin, k > 0).
function Expr.smoothUnion(a: Node, b: Node, k: number): Node
	return node(SMIN, a, b, k)
end
function Expr.subtract(a: Node, b: Node): Node
	return node(MAX, a, node(NEG, b))
end
-- Rounding: a - r.
function Expr.offset(a: Node, r: number): Node
	return node(OFFSET, a, nil, r)
end
-- Onion shell (outline): |a| - t.
function Expr.shell(a: Node, t: number): Node
	return node(SHELL, a, nil, t)
end

-- Deterministic demo: n circles and boxes, smooth-unioned in pairs, unioned, with
-- one subtracted hole and an outline ring. About 3 n nodes.
function Expr.demo(n: number, size: number, seed: number): Node
	local hash = MyMath.hash32
	local h = hash(seed)
	local function rnd(): number
		h = hash((h + 0x9E3779B9) % 4294967296)
		return h / 4294967296
	end
	local acc: Node? = nil
	for i = 1, n do
		local cx, cy = ((rnd() * size * 16) // 1) / 16, ((rnd() * size * 16) // 1) / 16
		local r = ((4 + rnd() * size * 0.06) * 16 // 1) / 16
		local s: Node
		if i % 2 == 0 then
			s = Expr.circle(cx, cy, r)
		else
			s = Expr.offset(Expr.box(cx, cy, r, r * 0.6), r * 0.2)
		end
		if acc == nil then
			acc = s
		elseif i % 3 == 0 then
			acc = Expr.smoothUnion(acc :: Node, s, 6)
		else
			acc = Expr.union(acc :: Node, s)
		end
	end
	local root = acc :: Node
	root = Expr.subtract(root, Expr.circle(size * 0.5, size * 0.5, size * 0.08))
	return Expr.union(root, Expr.shell(Expr.circle(size * 0.5, size * 0.5, size * 0.3), 2))
end

----------------------------------------------------------------------------------
-- Shared scalar ops (also the reference semantics)
----------------------------------------------------------------------------------

local sqrt, abs = math.sqrt, math.abs

local function sdBox(px: number, py: number, cx: number, cy: number, hx: number, hy: number): number
	local qx = abs(px - cx) - hx
	local qy = abs(py - cy) - hy
	local ox = if qx > 0 then qx else 0
	local oy = if qy > 0 then qy else 0
	local inside = if qx > qy then qx else qy
	if inside > 0 then
		inside = 0
	end
	return sqrt(ox * ox + oy * oy) + inside
end

local function smin(a: number, b: number, k: number): number
	local hh = 0.5 + 0.5 * (b - a) / k
	hh = if hh < 0 then 0 elseif hh > 1 then 1 else hh
	return b + (a - b) * hh - k * hh * (1 - hh)
end

----------------------------------------------------------------------------------
-- 1. Closures
----------------------------------------------------------------------------------

function Expr.closure(n: Node): (number, number) -> number
	local op = n.op
	if op == CIRCLE then
		local cx, cy, r = n.p1, n.p2, n.p3
		return function(px: number, py: number): number
			local dx, dy = px - cx, py - cy
			return sqrt(dx * dx + dy * dy) - r
		end
	elseif op == BOX then
		local cx, cy, hx, hy = n.p1, n.p2, n.p3, n.p4
		return function(px: number, py: number): number
			return sdBox(px, py, cx, cy, hx, hy)
		end
	end
	local fa = Expr.closure(n.a :: Node)
	if op == NEG then
		return function(px: number, py: number): number
			return -fa(px, py)
		end
	elseif op == OFFSET then
		local k = n.p1
		return function(px: number, py: number): number
			return fa(px, py) - k
		end
	elseif op == SHELL then
		local k = n.p1
		return function(px: number, py: number): number
			return abs(fa(px, py)) - k
		end
	end
	local fb = Expr.closure(n.b :: Node)
	if op == MIN then
		return function(px: number, py: number): number
			local a, b = fa(px, py), fb(px, py)
			return if a < b then a else b
		end
	elseif op == MAX then
		return function(px: number, py: number): number
			local a, b = fa(px, py), fb(px, py)
			return if a > b then a else b
		end
	end
	local k = n.p1
	return function(px: number, py: number): number
		return smin(fa(px, py), fb(px, py), k)
	end
end

----------------------------------------------------------------------------------
-- 2. Flat op array: {op, dst, a, b, k, ...} with constants inline
----------------------------------------------------------------------------------

export type Program = { code: { number }, len: number, nregs: number, out: number }

-- Instruction layouts (all fields are numbers):
--   CIRCLE dst cx cy r        BOX dst cx cy hx hy       MIN/MAX dst a b
--   SMIN dst a b k            NEG dst a                 OFFSET/SHELL dst a k
function Expr.compile(root: Node): Program
	local code: { number } = {}
	local nregs = 0
	local function emit(n: Node): number
		local op = n.op
		local dst
		if op == CIRCLE then
			nregs += 1
			dst = nregs
			table.move({ CIRCLE, dst, n.p1, n.p2, n.p3 }, 1, 5, #code + 1, code)
		elseif op == BOX then
			nregs += 1
			dst = nregs
			table.move({ BOX, dst, n.p1, n.p2, n.p3, n.p4 }, 1, 6, #code + 1, code)
		elseif op == NEG or op == OFFSET or op == SHELL then
			local a = emit(n.a :: Node)
			nregs += 1
			dst = nregs
			if op == NEG then
				table.move({ NEG, dst, a }, 1, 3, #code + 1, code)
			else
				table.move({ op, dst, a, n.p1 }, 1, 4, #code + 1, code)
			end
		else
			local a = emit(n.a :: Node)
			local b = emit(n.b :: Node)
			nregs += 1
			dst = nregs
			if op == SMIN then
				table.move({ SMIN, dst, a, b, n.p1 }, 1, 5, #code + 1, code)
			else
				table.move({ op, dst, a, b }, 1, 4, #code + 1, code)
			end
		end
		return dst
	end
	local out = emit(root)
	return { code = code, len = #code, nregs = nregs, out = out }
end

-- Per-pixel register machine. regs: table with at least prog.nregs slots.
function Expr.run(prog: Program, regs: { number }, px: number, py: number): number
	local code, len = prog.code, prog.len
	local pc = 1
	while pc <= len do
		local op = code[pc]
		if op == CIRCLE then
			local dx, dy = px - code[pc + 2], py - code[pc + 3]
			regs[code[pc + 1]] = sqrt(dx * dx + dy * dy) - code[pc + 4]
			pc += 5
		elseif op == MIN then
			local a, b = regs[code[pc + 2]], regs[code[pc + 3]]
			regs[code[pc + 1]] = if a < b then a else b
			pc += 4
		elseif op == BOX then
			local qx = abs(px - code[pc + 2]) - code[pc + 4]
			local qy = abs(py - code[pc + 3]) - code[pc + 5]
			local ox = if qx > 0 then qx else 0
			local oy = if qy > 0 then qy else 0
			local inside = if qx > qy then qx else qy
			if inside > 0 then
				inside = 0
			end
			regs[code[pc + 1]] = sqrt(ox * ox + oy * oy) + inside
			pc += 6
		elseif op == SMIN then
			local a, b, k = regs[code[pc + 2]], regs[code[pc + 3]], code[pc + 4]
			local hh = 0.5 + 0.5 * (b - a) / k
			hh = if hh < 0 then 0 elseif hh > 1 then 1 else hh
			regs[code[pc + 1]] = b + (a - b) * hh - k * hh * (1 - hh)
			pc += 5
		elseif op == MAX then
			local a, b = regs[code[pc + 2]], regs[code[pc + 3]]
			regs[code[pc + 1]] = if a > b then a else b
			pc += 4
		elseif op == OFFSET then
			regs[code[pc + 1]] = regs[code[pc + 2]] - code[pc + 3]
			pc += 4
		elseif op == SHELL then
			regs[code[pc + 1]] = abs(regs[code[pc + 2]]) - code[pc + 3]
			pc += 4
		else -- NEG
			regs[code[pc + 1]] = -regs[code[pc + 2]]
			pc += 3
		end
	end
	return regs[prog.out]
end

-- Column-at-a-time: evaluates pixels x0 .. x0 + n - 1 of row y; each register is
-- an array of n values (rows: table of prog.nregs arrays). Returns the output array.
function Expr.runRow(prog: Program, rows: { { number } }, y: number, x0: number, n: number): { number }
	local code, len = prog.code, prog.len
	local py = y + 0.5
	local pc = 1
	while pc <= len do
		local op = code[pc]
		local D = rows[code[pc + 1]]
		if op == CIRCLE then
			local cx, cy, r = code[pc + 2], code[pc + 3], code[pc + 4]
			local dy = py - cy
			local dy2 = dy * dy
			for i = 1, n do
				local dx = x0 + i - 0.5 - cx
				D[i] = sqrt(dx * dx + dy2) - r
			end
			pc += 5
		elseif op == MIN or op == MAX then
			local A, B = rows[code[pc + 2]], rows[code[pc + 3]]
			if op == MIN then
				for i = 1, n do
					local a, b = A[i], B[i]
					D[i] = if a < b then a else b
				end
			else
				for i = 1, n do
					local a, b = A[i], B[i]
					D[i] = if a > b then a else b
				end
			end
			pc += 4
		elseif op == BOX then
			local cx, cy, hx, hy = code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5]
			local qy = abs(py - cy) - hy
			local oy = if qy > 0 then qy else 0
			local oy2 = oy * oy
			for i = 1, n do
				local qx = abs(x0 + i - 0.5 - cx) - hx
				local ox = if qx > 0 then qx else 0
				local inside = if qx > qy then qx else qy
				if inside > 0 then
					inside = 0
				end
				D[i] = sqrt(ox * ox + oy2) + inside
			end
			pc += 6
		elseif op == SMIN then
			local A, B, k = rows[code[pc + 2]], rows[code[pc + 3]], code[pc + 4]
			for i = 1, n do
				local a, b = A[i], B[i]
				local hh = 0.5 + 0.5 * (b - a) / k
				hh = if hh < 0 then 0 elseif hh > 1 then 1 else hh
				D[i] = b + (a - b) * hh - k * hh * (1 - hh)
			end
			pc += 5
		elseif op == OFFSET or op == SHELL then
			local A, k = rows[code[pc + 2]], code[pc + 3]
			if op == OFFSET then
				for i = 1, n do
					D[i] = A[i] - k
				end
			else
				for i = 1, n do
					D[i] = abs(A[i]) - k
				end
			end
			pc += 4
		else
			local A = rows[code[pc + 2]]
			for i = 1, n do
				D[i] = -A[i]
			end
			pc += 3
		end
	end
	return rows[prog.out]
end

function Expr.newRows(prog: Program, n: number): { { number } }
	local rows: { { number } } = {}
	for i = 1, prog.nregs do
		rows[i] = table.create(n, 0)
	end
	return rows
end

----------------------------------------------------------------------------------
-- 3. Generated source
----------------------------------------------------------------------------------

local function num(x: number): string
	return string.format("%.17g", x)
end

-- Statements computing every register r<i> from px, py (same op order as run).
local function emitBody(prog: Program, lines: { string })
	local code = prog.code
	local pc = 1
	while pc <= prog.len do
		local op = code[pc]
		local d = "r" .. code[pc + 1]
		if op == CIRCLE then
			table.insert(lines, string.format("local dx_%s, dy_%s = px - %s, py - %s", d, d, num(code[pc + 2]), num(code[pc + 3])))
			table.insert(lines, string.format("local %s = sqrt(dx_%s * dx_%s + dy_%s * dy_%s) - %s", d, d, d, d, d, num(code[pc + 4])))
			pc += 5
		elseif op == BOX then
			table.insert(lines, string.format("local qx_%s = abs(px - %s) - %s", d, num(code[pc + 2]), num(code[pc + 4])))
			table.insert(lines, string.format("local qy_%s = abs(py - %s) - %s", d, num(code[pc + 3]), num(code[pc + 5])))
			table.insert(lines, string.format("local ox_%s = if qx_%s > 0 then qx_%s else 0", d, d, d))
			table.insert(lines, string.format("local oy_%s = if qy_%s > 0 then qy_%s else 0", d, d, d))
			table.insert(lines, string.format("local in_%s = if qx_%s > qy_%s then qx_%s else qy_%s", d, d, d, d, d))
			table.insert(lines, string.format("if in_%s > 0 then in_%s = 0 end", d, d))
			table.insert(lines, string.format("local %s = sqrt(ox_%s * ox_%s + oy_%s * oy_%s) + in_%s", d, d, d, d, d, d))
			pc += 6
		elseif op == MIN or op == MAX then
			local a, b = "r" .. code[pc + 2], "r" .. code[pc + 3]
			table.insert(lines, string.format("local %s = if %s %s %s then %s else %s", d, a, if op == MIN then "<" else ">", b, a, b))
			pc += 4
		elseif op == SMIN then
			local a, b, k = "r" .. code[pc + 2], "r" .. code[pc + 3], num(code[pc + 4])
			table.insert(lines, string.format("local h_%s = 0.5 + 0.5 * (%s - %s) / %s", d, b, a, k))
			table.insert(lines, string.format("h_%s = if h_%s < 0 then 0 elseif h_%s > 1 then 1 else h_%s", d, d, d, d))
			table.insert(lines, string.format("local %s = %s + (%s - %s) * h_%s - %s * h_%s * (1 - h_%s)", d, b, a, b, d, k, d, d))
			pc += 5
		elseif op == OFFSET then
			table.insert(lines, string.format("local %s = r%d - %s", d, code[pc + 2], num(code[pc + 3])))
			pc += 4
		elseif op == SHELL then
			table.insert(lines, string.format("local %s = abs(r%d) - %s", d, code[pc + 2], num(code[pc + 3])))
			pc += 4
		else
			table.insert(lines, string.format("local %s = -r%d", d, code[pc + 2]))
			pc += 3
		end
	end
end

-- Source of `function(px, py) -> number`. Luau limits a function to 200 locals,
-- so large programs should use sourceRow's register-reuse-free form in chunks.
function Expr.source(prog: Program): string
	local lines = { "local sqrt, abs = math.sqrt, math.abs", "return function(px: number, py: number): number" }
	emitBody(prog, lines)
	table.insert(lines, "return r" .. prog.out)
	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

-- Source of a row kernel `function(out: {number}, y, x0, n)` writing n values.
function Expr.sourceRow(prog: Program): string
	local lines = {
		"local sqrt, abs = math.sqrt, math.abs",
		"return function(out: {number}, y: number, x0: number, n: number)",
		"local py = y + 0.5",
		"for i = 1, n do",
		"local px = x0 + i - 0.5",
	}
	emitBody(prog, lines)
	table.insert(lines, "out[i] = r" .. prog.out)
	table.insert(lines, "end")
	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

----------------------------------------------------------------------------------
-- 4. Interval arithmetic: range of the expression over [x0, x1] x [y0, y1]
----------------------------------------------------------------------------------

-- Range of t^2 for t in [a, b].
local function sqRange(a: number, b: number): (number, number)
	if a >= 0 then
		return a * a, b * b
	elseif b <= 0 then
		return b * b, a * a
	end
	local m = if -a > b then -a else b
	return 0, m * m
end

-- Range of |t| for t in [a, b].
local function absRange(a: number, b: number): (number, number)
	if a >= 0 then
		return a, b
	elseif b <= 0 then
		return -b, -a
	end
	return 0, if -a > b then -a else b
end

function Expr.interval(n: Node, x0: number, x1: number, y0: number, y1: number): (number, number)
	local op = n.op
	if op == CIRCLE then
		local ax, bx = sqRange(x0 - n.p1, x1 - n.p1)
		local ay, by = sqRange(y0 - n.p2, y1 - n.p2)
		return sqrt(ax + ay) - n.p3, sqrt(bx + by) - n.p3
	elseif op == BOX then
		-- the box SDF is non-decreasing in |px - cx| and |py - cy|, so its range is
		-- spanned by the nearest and farthest |offsets| per axis
		local qxa, qxb = absRange(x0 - n.p1, x1 - n.p1)
		local qya, qyb = absRange(y0 - n.p2, y1 - n.p2)
		return sdBox(qxa, qya, 0, 0, n.p3, n.p4), sdBox(qxb, qyb, 0, 0, n.p3, n.p4)
	end
	local alo, ahi = Expr.interval(n.a :: Node, x0, x1, y0, y1)
	if op == NEG then
		return -ahi, -alo
	elseif op == OFFSET then
		return alo - n.p1, ahi - n.p1
	elseif op == SHELL then
		local lo, hi = absRange(alo, ahi)
		return lo - n.p1, hi - n.p1
	end
	local blo, bhi = Expr.interval(n.b :: Node, x0, x1, y0, y1)
	if op == MIN then
		return (if alo < blo then alo else blo), (if ahi < bhi then ahi else bhi)
	elseif op == MAX then
		return (if alo > blo then alo else blo), (if ahi > bhi then ahi else bhi)
	end
	-- smin is non-decreasing in both arguments (partial derivatives h and 1 - h)
	return smin(alo, blo, n.p1), smin(ahi, bhi, n.p1)
end

----------------------------------------------------------------------------------
-- Quadtree rendering of the field's coverage (linear ramp, AA width 1)
----------------------------------------------------------------------------------

export type QuadStats = { nodes: number, shaded: number, filled: number }

-- Renders coverage alpha of field f into an RGBA8 buffer (colour rgb, alpha from
-- coverage) through a quadtree. classify = "interval" uses Expr.interval on the
-- node's pixel-centre box; "lipschitz" evaluates the centre and assumes |grad| <= L.
-- A node whose range lies entirely beyond +-1/2 gets one span fill. Leaves of
-- `leaf` pixels are shaded per pixel by `f` (any backend).
function Expr.renderQuad(
	root: Node,
	f: (number, number) -> number,
	classify: string,
	L: number,
	out: buffer,
	size: number,
	rgb: number,
	leaf: number
): QuadStats
	local st: QuadStats = { nodes = 0, shaded = 0, filled = 0 }
	local useInterval = classify == "interval"
	local function visit(x: number, y: number, s: number)
		st.nodes += 1
		local lo, hi
		if useInterval then
			lo, hi = Expr.interval(root, x + 0.5, x + s - 0.5, y + 0.5, y + s - 0.5)
		else
			local d = f(x + s * 0.5, y + s * 0.5)
			local reach = L * (s - 1) * 0.70710678118654757
			lo, hi = d - reach, d + reach
		end
		if lo >= 0.5 then
			Pixels.fillRect(out, size, x, y, s, s, rgb)
			st.filled += s * s
			return
		elseif hi <= -0.5 then
			Pixels.fillRect(out, size, x, y, s, s, rgb + 0xFF000000)
			st.filled += s * s
			return
		end
		if s <= leaf then
			st.shaded += s * s
			for yy = y, y + s - 1 do
				local o = (yy * size + x) * 4
				for xx = x, x + s - 1 do
					local c = 0.5 - f(xx + 0.5, yy + 0.5)
					c = if c < 0 then 0 elseif c > 1 then 1 else c
					buffer.writeu32(out, o, rgb + ((c * 255 + 0.5) // 1) * 16777216)
					o += 4
				end
			end
			return
		end
		local h = s // 2
		visit(x, y, h)
		visit(x + h, y, h)
		visit(x, y + h, h)
		visit(x + h, y + h, h)
	end
	visit(0, 0, size)
	return st
end

return Expr
