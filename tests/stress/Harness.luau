--!nonstrict
-- universe-at-home :: tests/stress/Harness
--
-- A small harness for stress, fuzz and differential tests in the Luau CLI.
--   * seeded random numbers from MyMath.hash32 on a counter: every failure reproduces exactly
--   * three load levels, chosen by the first script argument: quick, standard (default), heavy
--       luau tests/stress/mymath.stress.luau -a heavy
--   * a digest: suites fold every deterministic result into one 32-bit value. The runner
--     (tests/stress.sh) compares the digest of the interpreter run with the native run, which
--     proves bit-identical results over millions of operations, not just a few hashes.
--   * failures print the suite, the message and the context set by the suite

local MyMath = require("../../src/MyMath")
local hash32 = MyMath.hash32

local Harness = {}

local SCALE = { quick = 0.15, standard = 1, heavy = 6 }
local level = "standard"
local ctx = ""
local cases = 0
local digestState = 0x1F2E3D4C

function Harness.setLevel(l: string?)
	if l ~= nil and SCALE[l] ~= nil then
		level = l
	end
end

function Harness.level(): string
	return level
end

-- Scales a base iteration count to the chosen level.
function Harness.n(base: number): number
	return math.max(1, math.floor(base * SCALE[level] + 0.5))
end

function Harness.context(s: string)
	ctx = s
end

function Harness.tick(n: number?)
	cases += n or 1
end

-- Asserts with a formatted message plus the current context.
function Harness.check(cond: any, fmt: string, ...)
	if not cond then
		local ok, msg = pcall(string.format, fmt, ...)
		error(string.format("%s  [%s]", if ok then msg else fmt, ctx), 2)
	end
end

----------------------------------------------------------------------------------------
-- Seeded random numbers
----------------------------------------------------------------------------------------

export type Rng = {
	u32: () -> number,
	float: () -> number,
	int: (number, number) -> number,
	range: (number, number) -> number,
	pick: ({ any }) -> any,
	bool: (number?) -> boolean,
}

function Harness.rng(seed: number): Rng
	local state = seed % 4294967296
	local r = {} :: any
	function r.u32(): number
		state = (state + 0x9E3779B9) % 4294967296
		return hash32(state)
	end
	function r.float(): number
		return r.u32() / 4294967296
	end
	function r.int(lo: number, hi: number): number
		return lo + r.u32() % (hi - lo + 1)
	end
	function r.range(a: number, b: number): number
		return a + (b - a) * r.float()
	end
	function r.pick(t: { any }): any
		return t[r.int(1, #t)]
	end
	function r.bool(p: number?): boolean
		return r.float() < (p or 0.5)
	end
	return r :: Rng
end

----------------------------------------------------------------------------------------
-- Digest: order-sensitive rolling hash of deterministic results
----------------------------------------------------------------------------------------

function Harness.digest(v: number)
	digestState = hash32(bit32.bxor(digestState, math.floor(v) % 4294967296))
end

-- For floating point results: quantised to 1e-9 so a one-ulp difference between runtimes
-- would still be caught only if it crosses a quantum; use digest for exact values.
function Harness.digestFloat(x: number)
	Harness.digest(math.floor(x * 1e9 + 0.5))
end

function Harness.digestBuffer(buf: buffer)
	for o = 0, buffer.len(buf) - 4, 4 do
		digestState = hash32(bit32.bxor(digestState, buffer.readu32(buf, o)))
	end
end

function Harness.digestValue(): number
	return digestState
end

----------------------------------------------------------------------------------------
-- Suites
----------------------------------------------------------------------------------------

local suites: { { name: string, fn: () -> () } } = {}

function Harness.suite(name: string, fn: () -> ())
	table.insert(suites, { name = name, fn = fn })
end

-- Runs every registered suite; prints one line each, then DIGEST and TOTAL lines.
-- Errors if any suite failed so the process exits non-zero.
function Harness.runAll(file: string)
	local failures = 0
	local start = os.clock()
	print(string.format("== %s  level=%s", file, level))
	for _, s in suites do
		ctx = ""
		cases = 0
		local t0 = os.clock()
		local ok, err = pcall(s.fn)
		local ms = (os.clock() - t0) * 1000
		if ok then
			print(string.format("PASS  %-62s cases=%-9d %8.0f ms", s.name, cases, ms))
		else
			failures += 1
			print(string.format("FAIL  %-62s %s", s.name, tostring(err)))
		end
	end
	print(string.format("DIGEST %s %08x", file, digestState))
	print(string.format("TOTAL %s %.0f ms, %d suites, %d failed", file, (os.clock() - start) * 1000, #suites, failures))
	if failures > 0 then
		error(failures .. " stress suite(s) failed in " .. file)
	end
end

return Harness
