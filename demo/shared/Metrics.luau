--!strict
-- Universe at Home: Meadow :: Metrics
--
-- Pure helpers for the always-on HUD: a ring buffer of frame times with mean FPS and
-- percentiles, and number formatting. The engine sampling (Stats, memory tags) lives
-- in the client HUD; this part is tested in the CLI.

local Metrics = {}

export type Ring = {
	size: number,
	values: buffer,
	count: number,
	head: number,
	sum: number,
}

function Metrics.ring(size: number): Ring
	return { size = size, values = buffer.create(size * 8), count = 0, head = 0, sum = 0 }
end

function Metrics.push(r: Ring, v: number)
	local o = r.head * 8
	if r.count == r.size then
		r.sum -= buffer.readf64(r.values, o)
	else
		r.count += 1
	end
	buffer.writef64(r.values, o, v)
	r.sum += v
	r.head = (r.head + 1) % r.size
end

function Metrics.mean(r: Ring): number
	if r.count == 0 then
		return 0
	end
	return r.sum / r.count
end

-- p in [0, 1]; nearest-rank percentile of the stored values.
function Metrics.percentile(r: Ring, p: number): number
	local n = r.count
	if n == 0 then
		return 0
	end
	local t = table.create(n, 0)
	for i = 0, n - 1 do
		t[i + 1] = buffer.readf64(r.values, i * 8)
	end
	table.sort(t)
	local idx = math.floor(p * (n - 1) + 0.5) + 1
	if idx < 1 then
		idx = 1
	elseif idx > n then
		idx = n
	end
	return t[idx]
end

-- Frames per second from a ring of frame durations in seconds.
function Metrics.fps(r: Ring): number
	local m = Metrics.mean(r)
	return if m > 0 then 1 / m else 0
end

function Metrics.formatMb(mb: number): string
	if mb >= 1024 then
		return string.format("%.2f GB", mb / 1024)
	end
	return string.format("%.1f MB", mb)
end

function Metrics.formatCount(n: number): string
	if n >= 1e6 then
		return string.format("%.2fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.1fk", n / 1e3)
	end
	return string.format("%d", n)
end

-- Exponential moving average with a time constant in seconds.
function Metrics.ema(previous: number, value: number, dt: number, tau: number): number
	local a = dt / (tau + dt)
	return previous + (value - previous) * a
end

return Metrics
