-- Verification of minisign signatures (Ed25519 over a BLAKE2b-512 prehash), so that installing the
-- server needs no tool beyond curl and tar. It only verifies public data, so it is not
-- constant-time. The field and group arithmetic follows TweetNaCl: field elements are 16 limbs of
-- 16 bits held in doubles; 64-bit words (SHA-512, BLAKE2b) are pairs of unsigned 32-bit halves.

local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, arshift = bit.lshift, bit.rshift, bit.arshift
local floor = math.floor

local M = {}

local U = 4294967296

-- 64-bit words -------------------------------------------------------------------------------

local function add64(ah, al, bh, bl)
  local l = al + bl
  return (ah + bh + floor(l / U)) % U, l % U
end

local function rotr64(h, l, n)
  if n >= 32 then
    h, l, n = l, h, n - 32
  end
  if n == 0 then return h, l end
  return bor(rshift(h, n), lshift(l, 32 - n)) % U, bor(rshift(l, n), lshift(h, 32 - n)) % U
end

local function shr64(h, l, n)
  return rshift(h, n) % U, bor(rshift(l, n), lshift(h, 32 - n)) % U
end

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((d * 256 + c) * 256 + b) * 256 + a
end

local function be32bytes(x)
  return string.char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
end

local function le32bytes(x)
  return string.char(x % 256, floor(x / 256) % 256, floor(x / 65536) % 256, floor(x / 16777216) % 256)
end

-- SHA-512 ------------------------------------------------------------------------------------

-- High and low halves of the round constants
local K = {
  0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
  0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
  0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
  0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
  0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
  0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
  0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
  0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
  0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
  0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
  0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
  0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
  0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
  0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
  0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
  0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
  0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
  0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
  0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
  0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

-- High and low halves of the initial hash value of SHA-512, which BLAKE2b uses too
local IV = {
  0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
  0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
}

--- The SHA-512 digest (64 bytes) of `msg`
---@param msg string
---@return string
function M.sha512(msg)
  local len = #msg
  local bits = len * 8
  msg = msg
    .. '\128'
    .. string.rep('\0', (128 - (len + 17) % 128) % 128 + 8)
    .. be32bytes(floor(bits / U))
    .. be32bytes(bits % U)
  local H = {}
  for i = 1, 16 do
    H[i] = IV[i]
  end
  local wh, wl = {}, {}
  for blk = 1, #msg, 128 do
    for t = 0, 15 do
      wh[t], wl[t] = be32(msg, blk + t * 8), be32(msg, blk + t * 8 + 4)
    end
    for t = 16, 79 do
      local xh, xl = wh[t - 15], wl[t - 15]
      local ah, al = rotr64(xh, xl, 1)
      local bh, bl = rotr64(xh, xl, 8)
      local ch, cl = shr64(xh, xl, 7)
      local s0h, s0l = bxor(ah, bh, ch) % U, bxor(al, bl, cl) % U
      xh, xl = wh[t - 2], wl[t - 2]
      ah, al = rotr64(xh, xl, 19)
      bh, bl = rotr64(xh, xl, 61)
      ch, cl = shr64(xh, xl, 6)
      local s1h, s1l = bxor(ah, bh, ch) % U, bxor(al, bl, cl) % U
      local h, l = add64(wh[t - 16], wl[t - 16], s0h, s0l)
      h, l = add64(h, l, wh[t - 7], wl[t - 7])
      wh[t], wl[t] = add64(h, l, s1h, s1l)
    end
    local ah, al, bh, bl, ch, cl, dh, dl = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    local eh, el, fh, fl, gh, gl, hh, hl = H[9], H[10], H[11], H[12], H[13], H[14], H[15], H[16]
    for t = 0, 79 do
      local x1h, x1l = rotr64(eh, el, 14)
      local x2h, x2l = rotr64(eh, el, 18)
      local x3h, x3l = rotr64(eh, el, 41)
      local t1h, t1l = add64(hh, hl, bxor(x1h, x2h, x3h) % U, bxor(x1l, x2l, x3l) % U)
      t1h, t1l = add64(
        t1h,
        t1l,
        bxor(band(eh, fh), band(bnot(eh), gh)) % U,
        bxor(band(el, fl), band(bnot(el), gl)) % U
      )
      t1h, t1l = add64(t1h, t1l, K[2 * t + 1], K[2 * t + 2])
      t1h, t1l = add64(t1h, t1l, wh[t], wl[t])
      x1h, x1l = rotr64(ah, al, 28)
      x2h, x2l = rotr64(ah, al, 34)
      x3h, x3l = rotr64(ah, al, 39)
      local t2h, t2l = add64(
        bxor(x1h, x2h, x3h) % U,
        bxor(x1l, x2l, x3l) % U,
        bxor(band(ah, bh), band(ah, ch), band(bh, ch)) % U,
        bxor(band(al, bl), band(al, cl), band(bl, cl)) % U
      )
      hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
      eh, el = add64(dh, dl, t1h, t1l)
      dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
      ah, al = add64(t1h, t1l, t2h, t2l)
    end
    local v = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
    for i = 1, 16, 2 do
      H[i], H[i + 1] = add64(H[i], H[i + 1], v[i], v[i + 1])
    end
  end
  local out = {}
  for i = 1, 16 do
    out[i] = be32bytes(H[i])
  end
  return table.concat(out)
end

-- BLAKE2b ------------------------------------------------------------------------------------

local SIGMA = {
  { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
  { 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
  { 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
  { 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
  { 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
  { 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
  { 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
  { 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
  { 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
  { 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
}

local function mix(vh, vl, a, b, c, d, xh, xl, yh, yl)
  local h, l = add64(vh[a], vl[a], vh[b], vl[b])
  vh[a], vl[a] = add64(h, l, xh, xl)
  vh[d], vl[d] = bxor(vl[d], vl[a]) % U, bxor(vh[d], vh[a]) % U
  vh[c], vl[c] = add64(vh[c], vl[c], vh[d], vl[d])
  vh[b], vl[b] = rotr64(bxor(vh[b], vh[c]) % U, bxor(vl[b], vl[c]) % U, 24)
  h, l = add64(vh[a], vl[a], vh[b], vl[b])
  vh[a], vl[a] = add64(h, l, yh, yl)
  vh[d], vl[d] = rotr64(bxor(vh[d], vh[a]) % U, bxor(vl[d], vl[a]) % U, 16)
  vh[c], vl[c] = add64(vh[c], vl[c], vh[d], vl[d])
  vh[b], vl[b] = rotr64(bxor(vh[b], vh[c]) % U, bxor(vl[b], vl[c]) % U, 63)
end

local function compress(hh, hl, s, off, count, last)
  local vh, vl, mh, ml = {}, {}, {}, {}
  for i = 0, 7 do
    vh[i], vl[i] = hh[i], hl[i]
    vh[i + 8], vl[i + 8] = IV[2 * i + 1], IV[2 * i + 2]
  end
  vh[12], vl[12] = bxor(vh[12], floor(count / U)) % U, bxor(vl[12], count % U) % U
  if last then
    vh[14], vl[14] = bnot(vh[14]) % U, bnot(vl[14]) % U
  end
  for i = 0, 15 do
    ml[i], mh[i] = le32(s, off + 8 * i), le32(s, off + 8 * i + 4)
  end
  for r = 0, 11 do
    local x = SIGMA[r % 10 + 1]
    mix(vh, vl, 0, 4, 8, 12, mh[x[1]], ml[x[1]], mh[x[2]], ml[x[2]])
    mix(vh, vl, 1, 5, 9, 13, mh[x[3]], ml[x[3]], mh[x[4]], ml[x[4]])
    mix(vh, vl, 2, 6, 10, 14, mh[x[5]], ml[x[5]], mh[x[6]], ml[x[6]])
    mix(vh, vl, 3, 7, 11, 15, mh[x[7]], ml[x[7]], mh[x[8]], ml[x[8]])
    mix(vh, vl, 0, 5, 10, 15, mh[x[9]], ml[x[9]], mh[x[10]], ml[x[10]])
    mix(vh, vl, 1, 6, 11, 12, mh[x[11]], ml[x[11]], mh[x[12]], ml[x[12]])
    mix(vh, vl, 2, 7, 8, 13, mh[x[13]], ml[x[13]], mh[x[14]], ml[x[14]])
    mix(vh, vl, 3, 4, 9, 14, mh[x[15]], ml[x[15]], mh[x[16]], ml[x[16]])
  end
  for i = 0, 7 do
    hh[i] = bxor(hh[i], vh[i], vh[i + 8]) % U
    hl[i] = bxor(hl[i], vl[i], vl[i + 8]) % U
  end
end

--- The unkeyed BLAKE2b-512 digest (64 bytes) of `msg`
---@param msg string
---@return string
function M.blake2b(msg)
  local hh, hl = {}, {}
  for i = 0, 7 do
    hh[i], hl[i] = IV[2 * i + 1], IV[2 * i + 2]
  end
  -- Parameter block: digest length 64, no key, fanout 1, depth 1
  hl[0] = bxor(hl[0], 0x01010040) % U
  local len = #msg
  local blocks = math.max(1, math.ceil(len / 128))
  local s = msg .. string.rep('\0', blocks * 128 - len)
  for b = 1, blocks do
    compress(hh, hl, s, (b - 1) * 128 + 1, b == blocks and len or b * 128, b == blocks)
  end
  local out = {}
  for i = 0, 7 do
    out[#out + 1] = le32bytes(hl[i]) .. le32bytes(hh[i])
  end
  return table.concat(out)
end

-- Ed25519 ------------------------------------------------------------------------------------

local function gf(init)
  local r = {}
  for i = 0, 15 do
    r[i] = init and init[i + 1] or 0
  end
  return r
end

local gf0, gf1 = gf(), gf({ 1 })
local D = gf({ 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 })
local D2 = gf({ 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 })
local X = gf({ 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 })
local Y = gf({ 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 })
local I = gf({ 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 })
-- The group order, little-endian
local L = { [0] = 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

local function set(r, a)
  for i = 0, 15 do
    r[i] = a[i]
  end
end

local function carry(o)
  local c = 1
  for i = 0, 15 do
    local v = o[i] + c + 65535
    c = floor(v / 65536)
    o[i] = v - c * 65536
  end
  o[0] = o[0] + c - 1 + 37 * (c - 1)
end

local function swap(p, q, b)
  if b == 1 then
    for i = 0, 15 do
      p[i], q[i] = q[i], p[i]
    end
  end
end

local function pack25519(o, n)
  local m, t = gf(), gf()
  set(t, n)
  carry(t)
  carry(t)
  carry(t)
  for _ = 1, 2 do
    m[0] = t[0] - 0xffed
    for i = 1, 14 do
      m[i] = t[i] - 0xffff - band(arshift(m[i - 1], 16), 1)
      m[i - 1] = band(m[i - 1], 0xffff)
    end
    m[15] = t[15] - 0x7fff - band(arshift(m[14], 16), 1)
    local b = band(arshift(m[15], 16), 1)
    m[14] = band(m[14], 0xffff)
    swap(t, m, 1 - b)
  end
  for i = 0, 15 do
    o[2 * i] = band(t[i], 0xff)
    o[2 * i + 1] = rshift(t[i], 8)
  end
end

local function differ(a, b)
  local c, d = {}, {}
  pack25519(c, a)
  pack25519(d, b)
  for i = 0, 31 do
    if c[i] ~= d[i] then return true end
  end
  return false
end

local function parity(a)
  local d = {}
  pack25519(d, a)
  return band(d[0], 1)
end

local function unpack25519(o, n)
  for i = 0, 15 do
    o[i] = n[2 * i] + n[2 * i + 1] * 256
  end
  o[15] = band(o[15], 0x7fff)
end

local function fadd(o, a, b)
  for i = 0, 15 do
    o[i] = a[i] + b[i]
  end
end

local function fsub(o, a, b)
  for i = 0, 15 do
    o[i] = a[i] - b[i]
  end
end

local T = {}
local function fmul(o, a, b)
  for i = 0, 30 do
    T[i] = 0
  end
  for i = 0, 15 do
    local ai = a[i]
    for j = 0, 15 do
      T[i + j] = T[i + j] + ai * b[j]
    end
  end
  for i = 0, 14 do
    T[i] = T[i] + 38 * T[i + 16]
  end
  for i = 0, 15 do
    o[i] = T[i]
  end
  carry(o)
  carry(o)
end

local function inverse(o, i)
  local c = gf()
  set(c, i)
  for a = 253, 0, -1 do
    fmul(c, c, c)
    if a ~= 2 and a ~= 4 then fmul(c, c, i) end
  end
  set(o, c)
end

local function pow2523(o, i)
  local c = gf()
  set(c, i)
  for a = 250, 0, -1 do
    fmul(c, c, c)
    if a ~= 1 then fmul(c, c, i) end
  end
  set(o, c)
end

local function point()
  return { gf(), gf(), gf(), gf() }
end

local function padd(p, q)
  local a, b, c, d, e, f, g, h, t = gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf(), gf()
  fsub(a, p[2], p[1])
  fsub(t, q[2], q[1])
  fmul(a, a, t)
  fadd(b, p[1], p[2])
  fadd(t, q[1], q[2])
  fmul(b, b, t)
  fmul(c, p[4], q[4])
  fmul(c, c, D2)
  fmul(d, p[3], q[3])
  fadd(d, d, d)
  fsub(e, b, a)
  fsub(f, d, c)
  fadd(g, d, c)
  fadd(h, b, a)
  fmul(p[1], e, f)
  fmul(p[2], h, g)
  fmul(p[3], g, f)
  fmul(p[4], e, h)
end

local function pswap(p, q, b)
  for i = 1, 4 do
    swap(p[i], q[i], b)
  end
end

local function pack(r, p)
  local tx, ty, zi = gf(), gf(), gf()
  inverse(zi, p[3])
  fmul(tx, p[1], zi)
  fmul(ty, p[2], zi)
  pack25519(r, ty)
  r[31] = bxor(r[31], lshift(parity(tx), 7))
end

local function scalarmult(p, q, s)
  set(p[1], gf0)
  set(p[2], gf1)
  set(p[3], gf1)
  set(p[4], gf0)
  for i = 255, 0, -1 do
    local b = band(rshift(s[floor(i / 8)], i % 8), 1)
    pswap(p, q, b)
    padd(q, p)
    padd(p, p)
    pswap(p, q, b)
  end
end

local function scalarbase(p, s)
  local q = point()
  set(q[1], X)
  set(q[2], Y)
  set(q[3], gf1)
  fmul(q[4], X, Y)
  scalarmult(p, q, s)
end

local function modL(r, x)
  for i = 63, 32, -1 do
    local c = 0
    local j = i - 32
    while j < i - 12 do
      x[j] = x[j] + c - 16 * x[i] * L[j - (i - 32)]
      c = floor((x[j] + 128) / 256)
      x[j] = x[j] - c * 256
      j = j + 1
    end
    x[j] = x[j] + c
    x[i] = 0
  end
  local c = 0
  for j = 0, 31 do
    x[j] = x[j] + c - floor(x[31] / 16) * L[j]
    c = floor(x[j] / 256)
    x[j] = x[j] % 256
  end
  for j = 0, 31 do
    x[j] = x[j] - c * L[j]
  end
  for i = 0, 31 do
    x[i + 1] = x[i + 1] + floor(x[i] / 256)
    r[i] = x[i] % 256
  end
end

--- Decodes the point `p` (32 bytes) negated into `r`; false if `p` is not on the curve
local function unpackneg(r, p)
  local t, chk, num, den, den2, den4, den6 = gf(), gf(), gf(), gf(), gf(), gf(), gf()
  set(r[3], gf1)
  unpack25519(r[2], p)
  fmul(num, r[2], r[2])
  fmul(den, num, D)
  fsub(num, num, r[3])
  fadd(den, r[3], den)
  fmul(den2, den, den)
  fmul(den4, den2, den2)
  fmul(den6, den4, den2)
  fmul(t, den6, num)
  fmul(t, t, den)
  pow2523(t, t)
  fmul(t, t, num)
  fmul(t, t, den)
  fmul(t, t, den)
  fmul(r[1], t, den)
  fmul(chk, r[1], r[1])
  fmul(chk, chk, den)
  if differ(chk, num) then fmul(r[1], r[1], I) end
  fmul(chk, r[1], r[1])
  fmul(chk, chk, den)
  if differ(chk, num) then return false end
  if parity(r[1]) == rshift(p[31], 7) then fsub(r[1], gf0, r[1]) end
  fmul(r[4], r[1], r[2])
  return true
end

local function bytes(s)
  local r = {}
  for i = 1, #s do
    r[i - 1] = s:byte(i)
  end
  return r
end

--- Whether the little-endian scalar `s` (32 bytes) is below the group order
local function canonical(s)
  for i = 31, 0, -1 do
    if s[i] ~= L[i] then return s[i] < L[i] end
  end
  return false
end

--- Whether `sig` (64 bytes) is a valid Ed25519 signature of `msg` by the public key `pk` (32 bytes)
---@param sig string
---@param msg string
---@param pk string
---@return boolean
function M.ed25519_verify(sig, msg, pk)
  if #sig ~= 64 or #pk ~= 32 then return false end
  local s = bytes(sig:sub(33))
  if not canonical(s) then return false end
  local q = point()
  if not unpackneg(q, bytes(pk)) then return false end
  local h = bytes(M.sha512(sig:sub(1, 32) .. pk .. msg))
  local k = {}
  modL(k, h)
  local p = point()
  scalarmult(p, q, k)
  local b = point()
  scalarbase(b, s)
  padd(p, b)
  local r = {}
  pack(r, p)
  for i = 0, 31 do
    if r[i] ~= sig:byte(i + 1) then return false end
  end
  return true
end

-- minisign -----------------------------------------------------------------------------------

local function decode(s)
  local ok, raw = pcall(vim.base64.decode, s or '')
  return ok and raw or nil
end

--- Verifies `data` against `signature`, the text of a minisign signature file, with `key`, the
--- base64 line of a minisign public key. Only prehashed signatures (algorithm `ED`, which minisign
--- and zig-minisign create by default) are accepted.
---@param key string
---@param signature string
---@param data string
---@return string? trusted_comment The signed trusted comment
---@return string? err Why the signature was rejected
function M.verify(key, signature, data)
  local k = decode(key)
  if not k or #k ~= 42 or k:sub(1, 2) ~= 'Ed' then return nil, 'invalid public key' end
  local lines = vim.split(signature, '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = line:gsub('\r$', '')
  end
  if not vim.startswith(lines[1] or '', 'untrusted comment: ') then return nil, 'not a minisign signature' end
  local sig = decode(lines[2])
  if not sig or #sig ~= 74 then return nil, 'not a minisign signature' end
  if sig:sub(1, 2) ~= 'ED' then return nil, 'unsupported signature algorithm' end
  if sig:sub(3, 10) ~= k:sub(3, 10) then return nil, 'signed with another key' end
  local prefix = 'trusted comment: '
  if not vim.startswith(lines[3] or '', prefix) then return nil, 'no trusted comment' end
  local comment = lines[3]:sub(#prefix + 1)
  local global = decode(lines[4])
  if not global or #global ~= 64 then return nil, 'no trusted comment signature' end
  local pk = k:sub(11)
  if not M.ed25519_verify(sig:sub(11), M.blake2b(data), pk) then return nil, 'signature does not match' end
  if not M.ed25519_verify(global, sig:sub(11) .. comment, pk) then
    return nil, 'trusted comment signature does not match'
  end
  return comment
end

return M
