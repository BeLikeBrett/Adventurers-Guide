-- Compact calibrated RGB transport: 16 calibration pixels, then 12 bits per
-- pixel. Each channel uses 16 levels; the captured ramp corrects display gamma.
-- Framing and Fletcher checks reject incomplete/corrupted captures.

WoWAI_Codec = {}
local C = WoWAI_Codec

C.MAGIC1, C.MAGIC2 = 0xC7, 0x1A
C.BITS = 12
C.PREFIX = 16
C.MAX_FRAME_PAYLOAD = 720
C.MAX_PAYLOAD = 3200

function C.Fletcher16(bytes, from, to)
	local s1, s2 = 0, 0
	for i = from, to do
		s1 = (s1 + bytes[i]) % 255
		s2 = (s2 + s1) % 255
	end
	return s1, s2
end

-- Returns an array of cell values (0..63) and the number of bytes encoded.
function C.Encode(id, payload)
	local len = #payload
    assert(len<=C.MAX_FRAME_PAYLOAD,"Pixel frame too large")
	local bytes = {
		C.MAGIC1, C.MAGIC2,
		math.floor(id / 256) % 256, id % 256,
		math.floor(len / 256) % 256, len % 256,
	}
	for i = 1, len do
		bytes[#bytes + 1] = payload:byte(i)
	end
	local s1, s2 = C.Fletcher16(bytes, 3, 6 + len)
	bytes[#bytes + 1] = s1
	bytes[#bytes + 1] = s2

	local BITS = C.BITS
	local base = 2 ^ BITS
	local cells = {}
    for i=0,15 do cells[#cells+1]=i*273 end
	local acc, nbits = 0, 0
	for i = 1, #bytes do
		acc = acc * 256 + bytes[i]
		nbits = nbits + 8
		while nbits >= BITS do
			local shift = nbits - BITS
			cells[#cells + 1] = math.floor(acc / 2 ^ shift) % base
			nbits = shift
			acc = acc % 2 ^ nbits
		end
	end
	if nbits > 0 then
		cells[#cells + 1] = (acc * 2 ^ (BITS - nbits)) % base
	end
	return cells, #bytes
end

-- Four calibrated bits per channel.
function C.CellColor(v)
    return math.floor(v/256)%16/15,math.floor(v/16)%16/15,v%16/15
end
